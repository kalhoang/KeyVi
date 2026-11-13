// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Counts the heap allocations the calling thread makes while a closure runs. Used by the W1-A acceptance
// tests that prove the tap-safe primitives never allocate (PLT-R304, PLT-R305). Test-only: TestSupport is
// never linked into the app.
//
// Mechanism: when the process-wide `malloc_logger` hook (the one malloc stack logging installs) is set,
// libmalloc calls it on every allocation and free. The hook is looked up with `dlsym`, so nothing links
// against a non-public symbol. When it cannot be found, or a sanitizer replaces the allocator (Thread
// Sanitizer has its own), `isAvailable` is false and callers skip their allocation assertions.
//
// Caveat for callers: in debug builds a `for _ in 0..<n` loop allocates an iterator box per iteration, so
// measured loops use `while`.

internal import Darwin
internal import Synchronization

public enum AllocationCounter {
    private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE`: set for malloc, calloc, realloc and every other allocating call.
    private static let allocateFlag: UInt32 = 2
    private static let countingThread = Atomic<UInt>(0)
    private static let allocations = Atomic<Int>(0)
    private static let measurement = Mutex<Int>(0)

    /// The address of libmalloc's `malloc_logger` variable, if the running system exports it. Kept as an
    /// integer because raw pointers are not `Sendable`; only `rawCount` dereferences it, under `measurement`.
    private static let loggerSlotAddress: UInt? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "malloc_logger").map { UInt(bitPattern: $0) }
    }()

    private static var loggerSlot: UnsafeMutablePointer<MallocLogger?>? {
        loggerSlotAddress.flatMap { UnsafeMutablePointer(bitPattern: $0) }
    }

    /// True when a sanitizer runtime that replaces malloc is loaded.
    public static let isSanitizerActive: Bool = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(defaultHandle, "__tsan_init") != nil || dlsym(defaultHandle, "__asan_init") != nil
    }()

    /// True when counting works on this system: the hook exists, no sanitizer replaced malloc, and a known
    /// allocation is seen (positive control). Also absorbs first-use costs of the hook.
    public static let isAvailable: Bool = {
        guard loggerSlot != nil, !isSanitizerActive else { return false }
        _ = rawCount { free(malloc(16)) }
        return rawCount { free(malloc(16)) } >= 1
    }()

    /// Number of allocations made by the calling thread while `body` runs, or nil when counting is not
    /// available. Measurements are serialized process-wide; other threads are not counted.
    public static func count(_ body: () -> Void) -> Int? {
        guard isAvailable else { return nil }
        return rawCount(body)
    }

    private static func rawCount(_ body: () -> Void) -> Int {
        measurement.withLock { runs in
            runs += 1
            guard let slot = loggerSlot else { return 0 }
            let previous = slot.pointee
            allocations.store(0, ordering: .sequentiallyConsistent)
            countingThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            slot.pointee = { type, _, _, _, _, _ in
                guard type & AllocationCounter.allocateFlag != 0 else { return }
                let current = UInt(bitPattern: pthread_self())
                if current == AllocationCounter.countingThread.load(ordering: .relaxed) {
                    AllocationCounter.allocations.wrappingAdd(1, ordering: .relaxed)
                }
            }
            body()
            slot.pointee = previous
            countingThread.store(0, ordering: .sequentiallyConsistent)
            return allocations.load(ordering: .sequentiallyConsistent)
        }
    }
}
