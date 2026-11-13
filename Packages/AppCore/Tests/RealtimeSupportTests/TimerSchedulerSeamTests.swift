// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Skeleton seam tests (ADR 0313): keep green; owners may extend.
import Dispatch
import Synchronization
import Testing

@testable import RealtimeSupport

@Suite struct DispatchTimerSchedulerTests {
    @Test func oneShotFiresOnceOnItsQueue() async {
        let queue = DispatchQueue(label: "test.scheduler")
        let scheduler = DispatchTimerScheduler(queue: queue)
        let fired = Atomic<Int>(0)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            _ = scheduler.schedule(after: .milliseconds(5), leeway: .milliseconds(1)) {
                fired.wrappingAdd(1, ordering: .relaxed)
                done.resume()
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let firedCount = fired.load(ordering: .relaxed)
        #expect(firedCount == 1)
    }

    @Test func cancelledTimerNeverFires() async {
        let scheduler = DispatchTimerScheduler(queue: DispatchQueue(label: "test.cancel"))
        let fired = Atomic<Bool>(false)
        let timer = scheduler.schedule(after: .milliseconds(20), leeway: .zero) {
            fired.store(true, ordering: .relaxed)
        }
        timer.cancel()
        timer.cancel()
        try? await Task.sleep(for: .milliseconds(60))
        let didFire = fired.load(ordering: .relaxed)
        #expect(!didFire)
    }

    @Test func repeatingTimerFiresUntilCancelled() async {
        let scheduler = DispatchTimerScheduler(queue: DispatchQueue(label: "test.repeat"))
        let count = Atomic<Int>(0)
        let timer = scheduler.scheduleRepeating(every: .milliseconds(5), leeway: .milliseconds(1)) {
            count.wrappingAdd(1, ordering: .relaxed)
        }
        // Wait for at least two firings, bounded, so a loaded machine cannot make the test flaky.
        var waited = 0
        while count.load(ordering: .relaxed) < 2, waited < 200 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        timer.cancel()
        let atCancel = count.load(ordering: .relaxed)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(atCancel >= 2)
        let final = count.load(ordering: .relaxed)
        #expect(final <= atCancel + 1)
    }
}

@Suite struct AtomicUInt64ArrayTests {
    @Test func storeLoadIncrement() {
        let array = AtomicUInt64Array(count: 4, initialValue: 7)
        array.store(1, at: 0)
        array.increment(3, by: 5)
        #expect(array.snapshot() == [1, 7, 7, 12])
    }

    @Test func concurrentIncrementsAreNotLost() async {
        let array = AtomicUInt64Array(count: 1)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<10_000 { array.increment(0) } } }
        }
        #expect(array.load(0) == 80_000)
    }
}
