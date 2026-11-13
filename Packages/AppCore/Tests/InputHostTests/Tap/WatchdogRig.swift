// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test rig for TapWatchdog (W1-F2): virtual time, a callback watchdog driven by the test, a fake tap.
import RealtimeSupport
import TestSupport

@testable import InputHost

/// What the watchdog told its owner.
enum WatchdogReport: Hashable {
    case trip(TapTrip)
    case callbackReturned
}

/// Forwards to `ManualScheduler` and records every request, so tests can check PLT-R803 leeways.
final class RecordingScheduler: TimerScheduler, Sendable {
    struct Request: Hashable {
        var delay: TimeSpan
        var leeway: TimeSpan
        var repeating: Bool
    }

    let manual: ManualScheduler
    private let log = Mutex<[Request]>([])

    init(_ manual: ManualScheduler) { self.manual = manual }

    var requests: [Request] { log.withLock { $0 } }

    func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        log.withLock { $0.append(Request(delay: delay, leeway: leeway, repeating: false)) }
        return manual.schedule(after: delay, leeway: leeway, handler)
    }

    func scheduleRepeating(every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        log.withLock { $0.append(Request(delay: interval, leeway: leeway, repeating: true)) }
        return manual.scheduleRepeating(every: interval, leeway: leeway, handler)
    }
}

/// Reports with the virtual time they arrived at.
final class ReportLog: Sendable {
    private let entries = Mutex<[(WatchdogReport, MonotonicInstant)]>([])
    func append(_ report: WatchdogReport, at time: MonotonicInstant) { entries.withLock { $0.append((report, time)) } }
    var reports: [WatchdogReport] { entries.withLock { $0.map(\.0) } }
    var times: [MonotonicInstant] { entries.withLock { $0.map(\.1) } }
}

final class WatchdogRig: Sendable {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let recording: RecordingScheduler
    let callbacks = CallbackWatchdog(activitySignal: nil)
    let tap: FakeTapControl
    let reclaimer = FakeSnapshotReclaimer()
    let watchdog: TapWatchdog
    let log = ReportLog()

    init(tap: FakeTapControl = FakeTapControl()) {
        self.tap = tap
        scheduler = ManualScheduler(clock: clock)
        recording = RecordingScheduler(scheduler)
        let log = self.log
        let clock = self.clock
        watchdog = TapWatchdog(
            tap: tap, callbacks: callbacks, snapshots: reclaimer, scheduler: recording, clock: clock,
            onCallbackReturned: { log.append(.callbackReturned, at: clock.now()) },
            onTrip: { trip in log.append(.trip(trip), at: clock.now()) })
    }

    var reports: [WatchdogReport] { log.reports }
    var reportTimes: [MonotonicInstant] { log.times }

    /// The tap thread enters a callback now; its first entry after 2 s idle arms the 250 ms check, as the
    /// activity `WakeSignal` would in production.
    func enterCallback(signalActivity: Bool = true) {
        callbacks.enter(at: clock.now())
        if signalActivity { watchdog.callbackActivity() }
    }

    func exitCallback() { callbacks.exit() }

    func advance(by duration: TimeSpan) { scheduler.advance(by: duration) }

    var repeatingIntervals: [TimeSpan] { scheduler.repeatingIntervals.sorted() }

    /// Starts the watchdog and runs one callback that stays inside until it trips.
    func tripNow() {
        watchdog.start()
        enterCallback()
        advance(by: .milliseconds(260))
    }
}
