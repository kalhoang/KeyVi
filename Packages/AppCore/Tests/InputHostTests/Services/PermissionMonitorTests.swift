// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R731, PLT-R803: health, stale grants, the live
// Input Monitoring check and polling cadence.

import AppModel
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

private struct Harness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let timers: TimerRequestRecorder
    let probe: FakePermissionProbe
    let store: InMemoryKeyValueStore
    let changes = Recorder<PermissionStatus>()
    let monitor: PermissionMonitor

    init(trusted: Bool = true, post: Bool = true, listen: Bool = true, store: InMemoryKeyValueStore = .init()) {
        scheduler = ManualScheduler(clock: clock)
        timers = TimerRequestRecorder(base: scheduler)
        probe = FakePermissionProbe(trusted: trusted, post: post, listen: listen)
        self.store = store
        let changes = self.changes
        monitor = PermissionMonitor(probe: probe, store: store, scheduler: timers) { changes.append($0) }
    }
}

/// `FakePermissionProbe` plus the live Input Monitoring check of the production probe (a listen-only key tap
/// created and released at once, `SystemPermissionProbe.canListenToEventsNow`), counting its calls.
private final class LiveListenProbe: PermissionProbe, Sendable {
    let base: FakePermissionProbe
    private let state = Mutex((live: false, calls: 0))

    init(trusted: Bool, post: Bool, listen: Bool) {
        base = FakePermissionProbe(trusted: trusted, post: post, listen: listen)
    }

    func setLive(_ live: Bool) { state.withLock { $0.live = live } }
    var liveCalls: Int { state.withLock { $0.calls } }

    func isAccessibilityTrusted() -> Bool { base.isAccessibilityTrusted() }
    func canPostEvents() -> Bool { base.canPostEvents() }
    func canListenToEvents() -> Bool { base.canListenToEvents() }
    func canListenToEventsNow() -> Bool {
        state.withLock {
            $0.calls += 1
            return $0.live
        }
    }
    func promptForAccessibility() { base.promptForAccessibility() }
    func requestListenEventAccess() -> Bool { base.requestListenEventAccess() }
    func requestPostEventAccess() -> Bool { base.requestPostEventAccess() }
    func signingIdentityDigest() -> String? { base.signingIdentityDigest() }
}

@Suite("PermissionMonitor (PLT-R720, PLT-R721)")
struct PermissionMonitorTests {
    @Test func everyTwoSecondsWhileNotReady() {
        let harness = Harness(trusted: false)
        harness.monitor.start()
        #expect(harness.changes.last?.health == .noPermission)
        #expect(harness.changes.last?.accessibility == .denied)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(2)])
    }

    @Test func everyThirtySecondsOnceReadyAndBack() {
        let harness = Harness(trusted: false)
        harness.monitor.start()
        harness.probe.set(trusted: true, post: true, listen: true)
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.changes.last?.health == .ready)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(30)])
        harness.probe.set(trusted: false, post: false, listen: true)
        harness.scheduler.advance(by: .seconds(30))
        #expect(harness.changes.last?.health != .ready)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(2)])
    }

    @Test func onboardingPollsEverySecondForAtMostFiveMinutes() {
        let harness = Harness(trusted: false)
        harness.monitor.start()
        harness.monitor.setFastPolling(true)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(1)])
        // PLT-R803 leeway of 10 % on a deadline that must not pass 5 minutes (PLT-R711): due at 270 s, 30 s leeway.
        #expect(
            harness.timers.requests.filter { !$0.repeating } == [
                .init(delay: .seconds(270), leeway: .seconds(30), repeating: false)
            ])
        harness.scheduler.advance(by: .seconds(269))
        #expect(harness.scheduler.repeatingIntervals == [.seconds(1)])
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.scheduler.repeatingIntervals == [.seconds(2)])  // PLT-R711 limit reached
        harness.monitor.setFastPolling(true)
        harness.monitor.setFastPolling(false)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(2)])
    }

    @Test func noRepeatingTimerShorterThanTwoSecondsAtRest() {
        for trusted in [false, true] {
            let harness = Harness(trusted: trusted)
            harness.monitor.start()
            harness.scheduler.advance(by: .seconds(120))
            #expect(harness.scheduler.repeatingIntervals.allSatisfy { $0 >= .seconds(2) })
            harness.monitor.setFastPolling(true)
            // PLT-R803: every timer, onboarding included, asks for at least 10 % leeway.
            #expect(harness.timers.requests.allSatisfy { $0.leeway * 10 >= $0.delay })
        }
    }

    @Test func inputMonitoringNeedIsNeverReportedAsStalePLTR702() {
        let store = InMemoryKeyValueStore()
        let first = Harness(listen: false, store: store)
        #expect(first.monitor.checkNow().health == .ready)  // grant recorded for this identity
        first.monitor.setTapUnavailable(true)
        #expect(first.changes.last?.health == .noPermission)
        #expect(first.changes.last?.listenEventRequired == true)
        first.probe.set(trusted: false, post: true, listen: false)
        #expect(first.monitor.checkNow().health == .stale)  // the Accessibility grant itself failed
    }

    @Test func staleWhenTheSameIdentityLosesItsGrant() {
        let store = InMemoryKeyValueStore()
        let first = Harness(store: store)
        #expect(first.monitor.checkNow().health == .ready)
        // Next launch (same signing identity) after a macOS update broke the grant.
        let second = Harness(trusted: false, post: false, store: store)
        #expect(second.monitor.checkNow().health == .stale)
    }

    @Test func notStaleWhenTheSigningIdentityChanged() {
        let store = InMemoryKeyValueStore()
        #expect(Harness(store: store).monitor.checkNow().health == .ready)
        let rebuilt = Harness(trusted: false, store: store)
        rebuilt.probe.setSigningIdentityDigest("another-team-identity")
        #expect(rebuilt.monitor.checkNow().health == .noPermission)
        let unsigned = Harness(trusted: false, store: store)
        unsigned.probe.setSigningIdentityDigest(nil)
        #expect(unsigned.monitor.checkNow().health == .noPermission)
    }

    @Test func inputMonitoringIsRequiredOnlyWhenTheTapFailsWithAccessibilityGranted() {
        let harness = Harness(listen: false)
        #expect(harness.monitor.checkNow().health == .ready)  // PLT-R702: not requested up front
        #expect(harness.monitor.checkNow().listenEventRequired == false)
        harness.monitor.setTapUnavailable(true)
        let status = harness.changes.last
        #expect(status?.listenEventRequired == true)
        // PLT-R712, not PLT-R740: the Accessibility grant works, so this is not `stale`.
        #expect(status?.health == .noPermission)
        harness.monitor.setTapUnavailable(true)
        harness.probe.set(trusted: false, post: true, listen: false)
        #expect(harness.monitor.checkNow().listenEventRequired == false)  // Accessibility first
        harness.probe.set(trusted: true, post: true, listen: true)
        #expect(harness.monitor.checkNow().health == .ready)
    }

    /// PLT-R701: `CGPreflightPostEventAccess()` keeps the answer it had when the process started (Apple DTS,
    /// developer forums threads 727984 and 720840), so it cannot gate readiness: on Pa's macOS 27.2 the switch of
    /// Device Control and Data Access was on, `AXIsProcessTrusted()` said so at once, and the screen still waited.
    @Test func aLiveAccessibilityGrantIsReadyWhileThePostPreflightKeepsItsLaunchAnswer_PLTR701() {
        let harness = Harness(trusted: false, post: false, listen: false)
        harness.monitor.start()
        #expect(harness.changes.last?.health == .noPermission)
        harness.probe.set(trusted: true, post: false, listen: false)
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.changes.last?.health == .ready)
        #expect(harness.changes.last?.accessibility == .granted)
        #expect(harness.changes.last?.listenEventRequired == false)  // PLT-R702: not asked up front
    }

    /// PLT-R720: `stale` is about the Accessibility grant of this signing identity only; the post preflight's
    /// launch-time answer never makes a working grant look stale.
    @Test func aStaleGrantIsAnAccessibilityFailureOnly_PLTR720() {
        let store = InMemoryKeyValueStore()
        #expect(Harness(store: store).monitor.checkNow().health == .ready)
        let relaunched = Harness(trusted: true, post: false, store: store)
        #expect(relaunched.monitor.checkNow().health == .ready)
        let broken = Harness(trusted: false, post: true, store: store)
        #expect(broken.monitor.checkNow().health == .stale)
    }

    /// PLT-R702, PLT-R731: Input Monitoring turned on while the app runs. The launch-time preflight still says
    /// denied; the live check (a listen-only key tap) says granted, so the need clears without a relaunch and the
    /// lifecycle creates the tap again.
    @Test func inputMonitoringTurnedOnWhileRunningClearsTheNeedWithoutARelaunch_PLTR731() {
        let probe = LiveListenProbe(trusted: true, post: true, listen: false)
        let changes = Recorder<PermissionStatus>()
        let scheduler = ManualScheduler(clock: ManualClock())
        let monitor = PermissionMonitor(probe: probe, store: InMemoryKeyValueStore(), scheduler: scheduler) {
            changes.append($0)
        }
        monitor.start()
        monitor.setTapUnavailable(true)
        #expect(changes.last?.listenEventRequired == true)
        #expect(changes.last?.health == .noPermission)
        probe.setLive(true)
        scheduler.advance(by: .seconds(2))
        #expect(changes.last?.listenEventRequired == false)
        #expect(changes.last?.listenEvent == .granted)
        #expect(changes.last?.health == .ready)
        monitor.stop()
    }

    /// PLT-R702: the live check creates a tap, and a tap for keys can make macOS prompt for Input Monitoring, so it
    /// runs only once the host knows the tap needs Input Monitoring, never while the app is merely polling.
    @Test func theLiveInputMonitoringCheckRunsOnlyOnceItIsNeeded_PLTR702() {
        let probe = LiveListenProbe(trusted: false, post: false, listen: false)
        let scheduler = ManualScheduler(clock: ManualClock())
        let monitor = PermissionMonitor(probe: probe, store: InMemoryKeyValueStore(), scheduler: scheduler) { _ in }
        monitor.start()
        monitor.setTapUnavailable(true)  // a tap failure without Accessibility says nothing about Input Monitoring
        scheduler.advance(by: .seconds(10))
        #expect(probe.liveCalls == 0)
        probe.base.set(trusted: true, post: false, listen: false)
        _ = monitor.checkNow()
        #expect(probe.liveCalls == 1)
        monitor.setTapUnavailable(false)
        scheduler.advance(by: .seconds(60))
        #expect(probe.liveCalls == 1)
        monitor.stop()
    }

    /// PLT-R702, PRD-R40: while a `ready` status is being delivered, the tap creation it triggers can fail and
    /// produce "needs Input Monitoring" (queued behind it). `latest` already answers with the newer status, so the
    /// host can tell a receiver that the status in hand was replaced and must not be forwarded.
    @Test(.timeLimit(.minutes(1))) func latestAnswersWithTheStatusThatReplacedTheOneBeingDelivered_PLTR702() {
        let probe = FakePermissionProbe(trusted: false, post: false, listen: false)
        let seenLatest = Recorder<PermissionStatus?>()
        let binding = LateBinding<PermissionMonitor>()
        let monitor = PermissionMonitor(
            probe: probe, store: InMemoryKeyValueStore(), scheduler: ManualScheduler(clock: ManualClock())
        ) { status in
            guard let monitor = binding.value else { return }
            if status.health == .ready { monitor.setTapUnavailable(true) }  // the lifecycle's tap creation failed
            seenLatest.append(monitor.latest)
        }
        binding.value = monitor
        #expect(monitor.latest == nil)
        monitor.start()
        probe.set(trusted: true, post: false, listen: false)
        _ = monitor.checkNow()
        let latest = seenLatest.values.compactMap { $0 }
        #expect(latest.map(\.health) == [.noPermission, .noPermission, .noPermission])
        #expect(latest.map(\.listenEventRequired) == [false, true, true])
        #expect(monitor.latest?.listenEventRequired == true)
        monitor.stop()
    }

    @Test func onChangeForTheFirstCheckAndForChangesOnly() {
        let harness = Harness()
        harness.monitor.start()
        harness.scheduler.advance(by: .seconds(90))
        #expect(harness.changes.count == 1)
        harness.probe.set(trusted: true, post: false, listen: true)
        #expect(harness.monitor.checkNow().postEvent == .denied)
        #expect(harness.changes.count == 2)
    }

    @Test func checkNowWithoutStartSchedulesNothing() {
        let harness = Harness()
        _ = harness.monitor.checkNow()
        harness.monitor.setFastPolling(false)
        #expect(harness.scheduler.repeatingIntervals.isEmpty)
    }

    @Test func stopCancelsEveryTimer() {
        let harness = Harness(trusted: false)
        harness.monitor.start()
        harness.monitor.setFastPolling(true)
        #expect(harness.scheduler.pendingCount == 2)
        harness.monitor.stop()
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func storesOnlyAHashOfTheIdentity() {
        let store = InMemoryKeyValueStore()
        _ = Harness(store: store).monitor.checkNow()
        let stored = store.integer(forKey: PermissionMonitor.lastGrantedDigestKey)
        #expect(stored == HostServicesHashing.stableHash52("fake-signing-identity"))
    }

    /// A lifecycle reaction may call `checkNow()` from `onChange` (PLT-R721): delivery happens outside the check
    /// lock, in check order, never nested.
    @Test(.timeLimit(.minutes(1))) func onChangeMayCallBackIntoTheMonitor() {
        let probe = FakePermissionProbe(trusted: true, post: true, listen: true)
        let changes = Recorder<PermissionStatus>()
        let nested = Recorder<PermissionStatus>()
        let nesting = NestingProbe()
        let binding = LateBinding<PermissionMonitor>()
        let monitor = PermissionMonitor(
            probe: probe, store: InMemoryKeyValueStore(), scheduler: ManualScheduler(clock: ManualClock())
        ) { status in
            nesting.run {
                changes.append(status)
                guard status.health == .ready, let monitor = binding.value else { return }
                probe.set(trusted: false, post: true, listen: true)
                nested.append(monitor.checkNow())
                monitor.setTapUnavailable(true)
            }
        }
        binding.value = monitor
        monitor.start()
        #expect(changes.values.map(\.health) == [.ready, .stale])
        #expect(nested.values.map(\.health) == [.stale])
        #expect(nesting.deepest == 1)
        monitor.stop()
    }
}

/// W8-F: `FakePermissionProbe` answers the live check itself, apart from the launch-time preflight, so host tests see
/// what production sees after a grant made while the app runs (PLT-R701, PLT-R731).
@Suite struct FakePermissionProbeLiveCheckTests {
    @Test func theLiveCheckHasItsOwnAnswer() {
        let harness = Harness(trusted: true, post: true, listen: false)
        harness.monitor.start()
        harness.monitor.setTapUnavailable(true)
        #expect(harness.changes.last?.listenEventRequired == true)
        harness.probe.setLiveListen(true)  // granted after launch: the preflight keeps saying no
        _ = harness.monitor.checkNow()
        #expect(harness.probe.canListenToEvents() == false)
        #expect(harness.changes.last?.health == .ready)
        #expect(harness.changes.last?.listenEventRequired == false)
        #expect(harness.probe.liveListenCheckCount >= 2)
    }
}
