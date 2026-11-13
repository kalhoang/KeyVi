// SPDX-License-Identifier: GPL-3.0-or-later
//
// ADR 0315: RealtimeSupport's `Mutex` replaces the macOS 15 `Synchronization.Mutex` with the same `withLock` API.

import Dispatch
import Testing

@testable import RealtimeSupport

@Suite struct MutexTests {
    private struct Failure: Error, Equatable {}

    @Test func withLockMutatesAndReturns() {
        let state = Mutex<[Int]>([])
        let count = state.withLock { values in
            values.append(1)
            values.append(2)
            return values.count
        }
        #expect(count == 2)
        #expect(state.withLock { $0 } == [1, 2])
    }

    @Test func typedErrorsPropagateAndReleaseTheLock() {
        let state = Mutex(0)
        #expect(throws: Failure.self) {
            try state.withLock { (value: inout Int) throws(Failure) -> Void in
                value = 5
                throw Failure()
            }
        }
        // The lock was released on the throwing path and the mutation before the throw stays.
        #expect(state.withLock { $0 } == 5)
    }

    @Test func copiesShareOneLockAndValue() {
        let original = Mutex("a")
        let copy = original
        copy.withLock { $0 += "b" }
        #expect(original.withLock { $0 } == "ab")
    }

    @Test func releasesItsValueWithTheLastCopy() {
        final class Tracked: @unchecked Sendable {
            let onDeinit: () -> Void
            init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        let released = Atomic<Bool>(false)
        do {
            let mutex = Mutex<Tracked?>(Tracked { released.store(true, ordering: .relaxed) })
            #expect(mutex.withLock { $0 != nil })
        }
        #expect(released.load(ordering: .relaxed))
    }

    /// Eight threads increment a plain integer under the lock: no lost update.
    @Test func excludesConcurrentWriters() {
        let counter = Mutex(0)
        let perThread = StressScale.isThreadSanitized ? 5_000 : 50_000
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            var index = 0
            while index < perThread {
                counter.withLock { $0 += 1 }
                index += 1
            }
        }
        #expect(counter.withLock { $0 } == 8 * perThread)
    }
}
