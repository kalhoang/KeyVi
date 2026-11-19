// SPDX-License-Identifier: MPL-2.0
//
// Counts the heap allocations the calling thread makes while a closure runs, for the tests that pin the
// allocation-free paths of the typo correction (ENG-R1122: the edit enumeration and the byte-keyed lookups run on
// preallocated tables). Test-only.
//
// Mechanism: libmalloc calls the process-wide `malloc_logger` hook (the one malloc stack logging installs) on every
// allocation and free when it is set. The hook is looked up with `dlsym`, so nothing links against a non-public
// symbol. When it cannot be found, a sanitizer replaced the allocator, or the system lacks the atomics of the
// Synchronization module, `isAvailable` is false and callers skip their allocation assertions.
//
// Caveat for callers: unoptimised builds may allocate in generic stdlib iteration, so measured loops use `while`.

import Darwin
import Synchronization

enum AllocationCounter {
    /// True when counting works here: the hook exists, no sanitizer replaced malloc, and a known allocation is seen.
    static var isAvailable: Bool {
        guard #available(macOS 15, *) else { return false }
        return Counter.isAvailable
    }

    /// The allocations the calling thread made while `body` ran, nil when counting is not available.
    static func count(_ body: () -> Void) -> Int? {
        guard #available(macOS 15, *), Counter.isAvailable else { return nil }
        return Counter.measure(body)
    }

    @available(macOS 15, *)
    private enum Counter {
        typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

        /// `MALLOC_LOG_TYPE_ALLOCATE`; realloc reports it too.
        static let allocateFlag: UInt32 = 2
        static let countingThread = Atomic<UInt>(0)
        static let allocations = Atomic<Int>(0)
        static let probeSink = Atomic<UInt>(0)
        /// One measurement at a time across the test process.
        static let measurement = Mutex<Int>(0)

        static let loggerSlotAddress: UInt? = {
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
            return dlsym(defaultHandle, "malloc_logger").map { UInt(bitPattern: $0) }
        }()

        static let isSanitizerActive: Bool = {
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
            return dlsym(defaultHandle, "__tsan_init") != nil || dlsym(defaultHandle, "__asan_init") != nil
        }()

        static let hook: MallocLogger = { type, _, _, _, _, _ in
            guard UInt(bitPattern: pthread_self()) == Counter.countingThread.load(ordering: .relaxed),
                type & Counter.allocateFlag != 0
            else { return }
            Counter.allocations.wrappingAdd(1, ordering: .relaxed)
        }

        static let isAvailable: Bool = {
            guard loggerSlotAddress != nil, !isSanitizerActive else { return false }
            _ = measure(probeAllocation)
            return measure(probeAllocation) >= 1
        }()

        static func probeAllocation() {
            let pointer = malloc(16)
            probeSink.store(UInt(bitPattern: pointer), ordering: .relaxed)
            free(pointer)
        }

        static func measure(_ body: () -> Void) -> Int {
            measurement.withLock { runs in
                runs += 1
                guard let address = loggerSlotAddress, let slot = UnsafeMutablePointer<UInt>(bitPattern: address)
                else { return -1 }
                allocations.store(0, ordering: .sequentiallyConsistent)
                countingThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
                let previous = slot.pointee
                slot.pointee = unsafeBitCast(hook, to: UInt.self)
                body()
                slot.pointee = previous
                countingThread.store(0, ordering: .sequentiallyConsistent)
                return allocations.load(ordering: .sequentiallyConsistent)
            }
        }
    }
}
