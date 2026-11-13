// SPDX-License-Identifier: GPL-3.0-or-later
//
// TapWatchdog with ManualScheduler and a CallbackWatchdog driven by the test (PLT-R306, PLT-R331, PLT-R803,
// ADR 0309, ADR 0303). W1-F2.
import Dispatch
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite struct TapWatchdogTripTests {
    @Test func callbackOverLimitTripsAndDisablesTheTap_PLT_R306() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        let entry = rig.clock.now()
        rig.enterCallback()
        rig.advance(by: .milliseconds(250))
        #expect(rig.reports.isEmpty, "exactly 250 ms is not over the limit")
        rig.advance(by: .milliseconds(30))
        #expect(rig.reports == [.trip(.callbackOverLimit(microseconds: 251_000))])
        #expect(rig.tap.enableCalls == [false], "CGEventTapEnable(false): keys flow")
        let latency = rig.reportTimes[0].nanoseconds(since: entry)
        #expect(latency <= 275_000_000, "ADR 0309: detection within about 275 ms")
    }

    @Test func callbackStartingBetweenChecksIsCaughtWhenItCrossesTheLimit() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.watchdog.callbackActivity()  // armed at t0, checks at 250, 500, ...
        rig.advance(by: .milliseconds(100))
        let entry = rig.clock.now()
        rig.enterCallback(signalActivity: false)
        rig.advance(by: .milliseconds(400))
        #expect(rig.reports == [.trip(.callbackOverLimit(microseconds: 251_000))])
        #expect(rig.reportTimes[0].nanoseconds(since: entry) <= 275_000_000)
    }

    @Test func callbacksUnderTheLimitNeverTrip() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        for _ in 0..<40 {
            rig.enterCallback()
            rig.advance(by: .milliseconds(200))
            rig.exitCallback()
            rig.advance(by: .milliseconds(60))
        }
        #expect(rig.reports.isEmpty)
        #expect(rig.tap.enableCalls.isEmpty)
    }

    @Test func secondCallbackAfterAShortOneIsStillWatched() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.enterCallback()
        rig.advance(by: .milliseconds(240))  // tick at 250 is still ahead
        rig.exitCallback()
        rig.advance(by: .milliseconds(5))
        rig.enterCallback(signalActivity: false)  // within 2 s: no new activity signal
        rig.advance(by: .milliseconds(600))
        #expect(rig.reports.first == .trip(.callbackOverLimit(microseconds: 251_000)))
    }
}

/// ADR 0309: recovery only once the callback returned; otherwise callbackStuck and nothing else.
@Suite struct TapWatchdogRecoveryTests {
    @Test func returnedCallbackIsReportedTwoSecondsAfterTheTrip_ADR0309() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.advance(by: .seconds(1))
        rig.exitCallback()
        rig.advance(by: .milliseconds(900))
        #expect(rig.reports.count == 1, "not before the 2 s recovery check")
        rig.advance(by: .milliseconds(200))
        #expect(rig.reports == [.trip(.callbackOverLimit(microseconds: 251_000)), .callbackReturned])
    }

    @Test func callbackStillInsideAtTwoSecondsIsStuck_ADR0309() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.advance(by: .seconds(2))
        #expect(
            rig.reports == [
                .trip(.callbackOverLimit(microseconds: 251_000)), .trip(.callbackStuck(microseconds: 2_251_000)),
            ])
        rig.advance(by: .seconds(60))
        #expect(rig.reports.count == 2, "stuck is reported once")
        #expect(rig.repeatingIntervals == [TapWatchdog.enabledCheckInterval], "no fast timer while stuck")
        #expect(rig.tap.enableCalls == [false], "a stuck tap is never re-enabled or touched again")
    }

    @Test func stuckCallbackThatReturnsLaterIsReportedOnTheNextEnabledTick() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.advance(by: .seconds(2))
        rig.exitCallback()
        rig.advance(by: .seconds(5))
        #expect(rig.reports.last == .callbackReturned)
    }

    @Test func activityAndEnabledChecksAreIgnoredWhileTheTapIsHeld() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.watchdog.callbackActivity()
        rig.watchdog.checkNow()
        #expect(rig.repeatingIntervals == [TapWatchdog.enabledCheckInterval])
        #expect(rig.reports.count == 1, "the disabled tap is the watchdog's own doing, not unexpected")
    }

    @Test func watchingResumesOnceTheLifecycleReenabledTheTap() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.exitCallback()
        rig.advance(by: .seconds(2))  // callbackReturned
        rig.watchdog.checkNow()
        #expect(rig.reports.count == 2, "the tap is still disabled by the watchdog: not unexpected")
        rig.tap.setEnabled(true)  // `.reenableTap` performed by the lifecycle owner
        rig.advance(by: .seconds(3))
        rig.enterCallback()
        #expect(rig.repeatingIntervals.contains(TapWatchdog.callbackCheckInterval), "armed again")
        rig.advance(by: .milliseconds(300))
        #expect(rig.reports.last == .trip(.callbackOverLimit(microseconds: 251_000)))
    }

    @Test func enabledTickReturnsToWatchingAfterReenable() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.exitCallback()
        rig.advance(by: .seconds(2))
        rig.tap.setEnabled(true)
        rig.advance(by: .seconds(5))  // tick sees the tap enabled again
        rig.tap.systemDisables()
        rig.advance(by: .seconds(5))
        #expect(rig.reports.last == .trip(.unexpectedlyDisabled))
    }
}

/// PLT-R331 and ADR 0303: the 5 s tick checks `isEnabled` and frees retired snapshot boxes.
@Suite struct TapWatchdogEnabledCheckTests {
    @Test func fiveSecondTickReclaimsSnapshotsEvenWhenIdle_ADR0303() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.advance(by: .seconds(4))
        #expect(rig.reclaimer.reclaimCount == 0)
        rig.advance(by: .seconds(11))
        #expect(rig.reclaimer.reclaimCount == 3)
        #expect(rig.reports.isEmpty)
    }

    @Test func unexpectedlyDisabledTapIsReportedOnEveryTick_PLT_R331() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.tap.systemDisables()
        rig.advance(by: .seconds(5))
        #expect(rig.reports == [.trip(.unexpectedlyDisabled)])
        rig.advance(by: .seconds(5))
        #expect(rig.reports == [.trip(.unexpectedlyDisabled), .trip(.unexpectedlyDisabled)])
    }

    @Test func checkNowReportsImmediately_PLT_R331() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.watchdog.checkNow()
        #expect(rig.reports.isEmpty)
        rig.tap.systemDisables()
        rig.watchdog.checkNow()
        #expect(rig.reports == [.trip(.unexpectedlyDisabled)])
        #expect(rig.reclaimer.reclaimCount == 0, "reclamation stays on the 5 s tick")
    }

    @Test func stoppedTapIsNotReportedAsDisabled() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.tap.stop()
        rig.advance(by: .seconds(5))
        #expect(rig.reports.isEmpty)
    }

    @Test func checkNowBeforeStartDoesNothing() {
        let rig = WatchdogRig(tap: FakeTapControl(enabled: false))
        rig.watchdog.checkNow()
        #expect(rig.reports.isEmpty)
    }
}

/// PLT-R803: nothing faster than every 2 s at rest, every timer with at least 10 % leeway.
@Suite struct TapWatchdogTimerTests {
    @Test func noRepeatingTimerFasterThanTwoSecondsWhileIdle_PLT_R803() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        #expect(rig.repeatingIntervals == [.seconds(5)])
        rig.enterCallback()
        rig.exitCallback()
        #expect(rig.repeatingIntervals == [.milliseconds(250), .seconds(5)])
        rig.advance(by: .milliseconds(2_100))
        #expect(rig.repeatingIntervals == [.milliseconds(250), .seconds(5)], "still inside the 2 s idle window")
        rig.advance(by: .milliseconds(300))
        #expect(rig.repeatingIntervals == [.seconds(5)], "disarmed after 2 s without callbacks")
        #expect(rig.scheduler.pendingCount == 1)
    }

    @Test func disarmsTwoSecondsAfterArmingWhenNoCallbackEntered() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.watchdog.callbackActivity()
        rig.advance(by: .milliseconds(1_900))
        #expect(rig.repeatingIntervals.contains(.milliseconds(250)))
        rig.advance(by: .milliseconds(400))
        #expect(rig.repeatingIntervals == [.seconds(5)])
    }

    @Test func everyTimerHasAtLeastTenPercentLeeway_PLT_R803() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.watchdog.callbackActivity()
        rig.advance(by: .milliseconds(100))
        rig.enterCallback(signalActivity: false)  // forces the crossing check
        rig.advance(by: .seconds(3))  // trip and stuck
        rig.exitCallback()
        rig.advance(by: .seconds(5))
        let kinds = Set(rig.recording.requests.map(\.repeating))
        #expect(kinds == [true, false], "both repeating and one-shot timers were exercised")
        for request in rig.recording.requests {
            #expect(request.leeway * 10 >= request.delay, "\(request)")
            if request.repeating && request.delay < .seconds(2) {
                #expect(request.delay == TapWatchdog.callbackCheckInterval, "only while keys flow (ADR 0309)")
            }
        }
    }

    @Test func activityWhileArmedDoesNotStackTimers() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        for _ in 0..<5 { rig.watchdog.callbackActivity() }
        #expect(rig.repeatingIntervals == [.milliseconds(250), .seconds(5)])
    }

    @Test func startTwiceKeepsOneEnabledCheck() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        rig.watchdog.start()
        #expect(rig.repeatingIntervals == [.seconds(5)])
    }

    @Test func activityBeforeStartIsIgnoredButRecentCallbacksArmAtStart() {
        let rig = WatchdogRig()
        rig.watchdog.callbackActivity()
        #expect(rig.scheduler.pendingCount == 0)
        rig.enterCallback()  // activity signal lost: the watchdog was not started yet
        rig.advance(by: .milliseconds(100))
        rig.watchdog.start()
        #expect(rig.repeatingIntervals == [.milliseconds(250), .seconds(5)])
        rig.advance(by: .milliseconds(300))
        #expect(rig.reports == [.trip(.callbackOverLimit(microseconds: 251_000))])
    }

    @Test func stopCancelsEveryTimerAndIgnoresLaterActivity() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.watchdog.stop()
        #expect(rig.scheduler.pendingCount == 0)
        rig.watchdog.callbackActivity()
        rig.watchdog.checkNow()
        rig.advance(by: .seconds(30))
        #expect(rig.scheduler.pendingCount == 0)
        #expect(rig.reports.count == 1)
        #expect(rig.reclaimer.reclaimCount == 0)
    }

    @Test func restartAfterStopWatchesAgain() {
        let rig = WatchdogRig()
        rig.tripNow()
        rig.watchdog.stop()
        rig.exitCallback()
        rig.tap.setEnabled(true)
        rig.advance(by: .seconds(3))
        rig.watchdog.start()
        rig.enterCallback()
        rig.advance(by: .milliseconds(300))
        #expect(rig.reports.count == 2)
    }

    @Test func releasingTheWatchdogCancelsItsTimers() {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        weak var weakWatchdog: TapWatchdog?
        do {
            let watchdog = TapWatchdog(
                tap: FakeTapControl(), callbacks: CallbackWatchdog(activitySignal: nil),
                snapshots: FakeSnapshotReclaimer(), scheduler: scheduler, clock: clock,
                onCallbackReturned: {}, onTrip: { _ in })
            watchdog.start()
            watchdog.callbackActivity()
            weakWatchdog = watchdog
        }
        #expect(weakWatchdog == nil, "timers do not keep the watchdog alive")
        #expect(scheduler.pendingCount == 0)
        scheduler.advance(by: .seconds(10))
    }
}

/// Thread Sanitizer target: owner calls from several threads while timers fire.
@Suite struct TapWatchdogConcurrencyTests {
    @Test func concurrentCallsKeepAtMostOneCallbackTimer() {
        let rig = WatchdogRig()
        rig.watchdog.start()
        let violations = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for step in 0..<2_000 {
                switch worker {
                case 0: rig.advance(by: .milliseconds(50))
                case 1: rig.watchdog.callbackActivity()
                case 2: rig.watchdog.checkNow()
                default:
                    if step % 2 == 0 { rig.callbacks.enter(at: rig.clock.now()) } else { rig.callbacks.exit() }
                }
                let fast = rig.scheduler.repeatingIntervals.filter { $0 < .seconds(2) }.count
                if fast > 1 { violations.wrappingAdd(1, ordering: .relaxed) }
            }
        }
        rig.watchdog.stop()
        #expect(violations.load(ordering: .relaxed) == 0)
        #expect(rig.scheduler.pendingCount == 0)
    }
}
