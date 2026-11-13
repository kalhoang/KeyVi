// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R803: health, stale grants and polling cadence.

import AppModel
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

private struct Harness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let probe: FakePermissionProbe
    let store: InMemoryKeyValueStore
    let changes = Recorder<PermissionStatus>()
    let monitor: PermissionMonitor

    init(trusted: Bool = true, post: Bool = true, listen: Bool = true, store: InMemoryKeyValueStore = .init()) {
        scheduler = ManualScheduler(clock: clock)
        probe = FakePermissionProbe(trusted: trusted, post: post, listen: listen)
        self.store = store
        let changes = self.changes
        monitor = PermissionMonitor(probe: probe, store: store, scheduler: scheduler) { changes.append($0) }
    }
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
        harness.scheduler.advance(by: .seconds(299))
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
        }
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
        #expect(status?.health != .ready)
        harness.monitor.setTapUnavailable(true)
        harness.probe.set(trusted: false, post: true, listen: false)
        #expect(harness.monitor.checkNow().listenEventRequired == false)  // Accessibility first
        harness.probe.set(trusted: true, post: true, listen: true)
        #expect(harness.monitor.checkNow().health == .ready)
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
}
