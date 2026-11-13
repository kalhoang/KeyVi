// SPDX-License-Identifier: GPL-3.0-or-later
//
// Counts the heap allocations (and frees) the calling thread makes while a closure runs. Used by the
// acceptance tests that prove the tap-safe primitives and the tap pipeline never allocate in steady state
// (PLT-R304, PLT-R305). Test-only: TestSupport is never linked into the app.
//
// Mechanism: when the process-wide `malloc_logger` hook (the one malloc stack logging installs) is set,
// libmalloc calls it on every allocation and free. The hook is looked up with `dlsym`, so nothing links
// against a non-public symbol. When it cannot be found, or a sanitizer replaces the allocator (Thread and
// Address Sanitizer have their own), `isAvailable` is false and callers skip their allocation assertions.
// Spans that must not be counted (for example the engine call inside the pipeline, whose own budget is
// ENG-R1230) are excluded with `pause()` / `resume()`.
//
// Caveat for callers: in debug builds a `for _ in 0..<n` loop allocates an iterator box per iteration, so
// measured loops use `while`.

internal import Darwin
internal import RealtimeSupport

public enum AllocationCounter {
    /// Allocations and frees seen on the measured thread outside paused spans; both are -1 when the hook is
    /// missing on this system.
    public struct Counts: Sendable, Hashable {
        public var allocations: Int
        public var deallocations: Int
    }

    private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` and `MALLOC_LOG_TYPE_DEALLOCATE`; realloc reports both.
    private static let allocateFlag: UInt32 = 2
    private static let deallocateFlag: UInt32 = 4
    private static let countingThread = Atomic<UInt>(0)
    private static let pauseDepth = Atomic<Int>(0)
    private static let allocations = Atomic<Int>(0)
    private static let deallocations = Atomic<Int>(0)
    /// One measurement at a time across the whole test process.
    private static let measurement = Mutex<Int>(0)

    /// The address of libmalloc's `malloc_logger` variable, if the running system exports it. Kept as an
    /// integer because raw pointers are not `Sendable`; only `rawMeasure` dereferences it, under `measurement`.
    private static let loggerSlotAddress: UInt? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "malloc_logger").map { UInt(bitPattern: $0) }
    }()

    /// The hook variable viewed as an atomic word. Plain stores would let an optimising compiler drop the
    /// install as a dead store (malloc and free are known not to read it); atomic stores are kept.
    private static var loggerSlot: UnsafeAtomic<UInt>? {
        loggerSlotAddress.flatMap { UnsafeMutablePointer<UInt64>(bitPattern: $0) }.map { UnsafeAtomic(at: $0) }
    }

    private static let hook: MallocLogger = { type, _, _, _, _, _ in
        guard UInt(bitPattern: pthread_self()) == AllocationCounter.countingThread.load(ordering: .relaxed),
            AllocationCounter.pauseDepth.load(ordering: .relaxed) == 0
        else { return }
        if type & AllocationCounter.allocateFlag != 0 {
            AllocationCounter.allocations.wrappingAdd(1, ordering: .relaxed)
        }
        if type & AllocationCounter.deallocateFlag != 0 {
            AllocationCounter.deallocations.wrappingAdd(1, ordering: .relaxed)
        }
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
        _ = rawMeasure(probeAllocation)
        return rawMeasure(probeAllocation).allocations >= 1
    }()

    /// Receives the probe pointer so an optimising compiler cannot delete the malloc/free pair.
    private static let probeSink = Atomic<UInt>(0)

    private static func probeAllocation() {
        let pointer = malloc(16)
        probeSink.store(UInt(bitPattern: pointer), ordering: .relaxed)
        free(pointer)
    }

    /// Number of allocations made by the calling thread while `body` runs, or nil when counting is not
    /// available. Measurements are serialized process-wide; other threads are not counted.
    public static func count(_ body: () -> Void) -> Int? {
        guard isAvailable else { return nil }
        return rawMeasure(body).allocations
    }

    /// Allocations and frees of the calling thread while `body` runs, outside `pause()`d spans. Returns -1
    /// for both when the hook is missing; check `isAvailable` before asserting on the numbers.
    public static func measure(_ body: () -> Void) -> Counts {
        rawMeasure(body)
    }

    /// Stops counting on the measured thread until the matching `resume()`; calls nest.
    public static func pause() { pauseDepth.wrappingAdd(1, ordering: .sequentiallyConsistent) }

    /// Ends one `pause()`.
    public static func resume() { pauseDepth.wrappingSubtract(1, ordering: .sequentiallyConsistent) }

    private static func rawMeasure(_ body: () -> Void) -> Counts {
        measurement.withLock { runs in
            runs += 1
            guard let slot = loggerSlot else { return Counts(allocations: -1, deallocations: -1) }
            allocations.store(0, ordering: .sequentiallyConsistent)
            deallocations.store(0, ordering: .sequentiallyConsistent)
            pauseDepth.store(0, ordering: .sequentiallyConsistent)
            countingThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            let previous = slot.exchange(unsafeBitCast(hook, to: UInt.self), ordering: .sequentiallyConsistent)
            body()
            slot.store(previous, ordering: .sequentiallyConsistent)
            countingThread.store(0, ordering: .sequentiallyConsistent)
            return Counts(
                allocations: allocations.load(ordering: .sequentiallyConsistent),
                deallocations: deallocations.load(ordering: .sequentiallyConsistent))
        }
    }
}
