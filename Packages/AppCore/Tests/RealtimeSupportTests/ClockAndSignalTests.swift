// SPDX-License-Identifier: LicenseRef-App-Pending

import Dispatch
import Testing

@testable import RealtimeSupport

@Suite struct MonotonicInstantTests {
    @Test func arithmeticSaturatesAndOrders() {
        let start = MonotonicInstant(nanoseconds: 5_000)
        let later = start.advanced(byMicroseconds: 3)
        #expect(later.nanoseconds == 8_000)
        #expect(later.nanoseconds(since: start) == 3_000)
        #expect(start.nanoseconds(since: later) == 0)  // saturating, never negative
        #expect(start < later)
        #expect(MonotonicInstant.zero < start)
        #expect(MonotonicInstant(nanoseconds: 8_000) == later)
    }
}

@Suite struct MachClockTests {
    @Test func nowIsMonotonic() {
        let clock = MachClock()
        let first = clock.now()
        let second = clock.now()
        #expect(second >= first)
        #expect(first.nanoseconds > 0)
    }

    /// The production clock is the one place where real time is the subject of the test: a past deadline
    /// returns at once, a 1 ms deadline is honoured (PLT-R409 absolute deadlines in mach ticks).
    @Test func sleepUntilHonoursAbsoluteDeadlines() {
        let clock = MachClock()
        clock.sleep(until: .zero)
        let deadline = clock.now().advanced(byMicroseconds: 1_000)
        clock.sleep(until: deadline)
        #expect(clock.now() >= deadline)
    }
}

@Suite struct SignalTests {
    @Test func wakeSignalRunsHandlerOnItsQueue() async {
        let queue = DispatchQueue(label: "test.wake")
        let key = DispatchSpecificKey<Int>()
        queue.setSpecific(key: key, value: 7)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let fired = Atomic<Bool>(false)
            let signal = WakeSignal(queue: queue) {
                #expect(DispatchQueue.getSpecific(key: key) == 7)
                if !fired.exchange(true, ordering: .relaxed) { done.resume() }
            }
            signal.signal()
            signal.signal()
            queue.async { signal.cancel() }
        }
    }

    @Test func workerSignalWakesAWaiter() {
        let signal = WorkerSignal()
        signal.signal()
        #expect(signal.wait(until: nil))
        signal.signal()
        #expect(signal.wait(until: MonotonicInstant(nanoseconds: .max)))
    }

    @Test func workerSignalTimesOutAtAPastDeadline() {
        let signal = WorkerSignal()
        #expect(!signal.wait(until: .zero))
    }
}

@Suite struct DurationConversionTests {
    @Test func convertsWithNanosecondPrecision() {
        #expect(TimeSpan.milliseconds(5).dispatchInterval == .nanoseconds(5_000_000))
        #expect(TimeSpan.nanoseconds(1).dispatchInterval == .nanoseconds(1))
        #expect(TimeSpan.seconds(2).dispatchInterval == .nanoseconds(2_000_000_000))
    }

    @Test func negativeBecomesZeroAndHugeSaturates() {
        #expect(TimeSpan.milliseconds(-5).dispatchInterval == .nanoseconds(0))
        #expect(TimeSpan.nanoseconds(-1).dispatchInterval == .nanoseconds(0))
        #expect(TimeSpan.seconds(Int64.max).dispatchInterval == .nanoseconds(Int.max))
        #expect(TimeSpan.seconds(Int64.max / 1_000_000_000).dispatchInterval != .nanoseconds(Int.max))
    }

    @Test func repeatingIntervalHasAFloor() async {
        let scheduler = DispatchTimerScheduler(queue: DispatchQueue(label: "test.floor"))
        #expect(DispatchTimerScheduler.minimumRepeatInterval == .milliseconds(1))
        let fired = Atomic<Int>(0)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let timer = scheduler.scheduleRepeating(every: .zero, leeway: .zero) {
                if fired.wrappingAdd(1, ordering: .relaxed).newValue == 2 { done.resume() }
            }
            // Keep the repeating timer alive until it has fired twice, then cancel it.
            Task.detached {
                while fired.load(ordering: .relaxed) < 2 { await Task.yield() }
                timer.cancel()
            }
        }
        #expect(fired.load(ordering: .relaxed) >= 2)
    }
}
