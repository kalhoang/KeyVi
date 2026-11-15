// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R721 (amended 15/11/2026): while a tap is installed, Accessibility is checked live every second, so removing
// the grant removes the tap within about one second of `AXIsProcessTrusted()` reporting it, even when macOS never
// disables the tap. PLT-R730: the probe calls
// run on the monitor's own runner, never on the caller's thread, and nothing the main thread reads or sets waits
// for a probe call that stalls (a TCC call blocked behind System Settings).

import AppModel
import Dispatch
import Foundation
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

/// A real serial queue, as production runs the probe calls.
private struct QueueRunner: PermissionCheckRunner {
    let queue: DispatchQueue
    func run(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

private struct LiveHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let probe: FakePermissionProbe
    let changes = Recorder<PermissionStatus>()
    let monitor: PermissionMonitor

    init(trusted: Bool = true, runner: any PermissionCheckRunner = InlinePermissionCheckRunner()) {
        scheduler = ManualScheduler(clock: clock)
        probe = FakePermissionProbe(trusted: trusted, post: trusted, listen: true)
        let changes = self.changes
        monitor = PermissionMonitor(
            probe: probe, store: InMemoryKeyValueStore(), scheduler: scheduler, runner: runner
        ) { changes.append($0) }
    }
}

@Suite("PermissionMonitor live Accessibility check (PLT-R721, PLT-R730)")
struct PermissionMonitorLiveCheckTests {
    @Test func aRevocationIsSeenWithinOneSecondWhileATapIsInstalled() {
        let harness = LiveHarness()
        harness.monitor.start()
        harness.monitor.setTapInstalled(true)
        #expect(harness.scheduler.repeatingIntervals.contains(PermissionMonitor.liveInterval))
        harness.probe.set(trusted: false, post: false, listen: true)
        harness.scheduler.advance(by: PermissionMonitor.liveInterval)
        #expect(harness.changes.last?.health != .ready, "\(String(describing: harness.changes.last))")
        #expect(harness.changes.last?.accessibility == .denied)
    }

    @Test func noOneSecondTimerWithoutAnInstalledTap() {
        let harness = LiveHarness()
        harness.monitor.start()
        #expect(harness.scheduler.repeatingIntervals.allSatisfy { $0 >= .seconds(2) })
        harness.monitor.setTapInstalled(true)
        harness.monitor.setTapInstalled(false)
        #expect(harness.scheduler.repeatingIntervals.allSatisfy { $0 >= .seconds(2) })
        harness.probe.set(trusted: false, post: false, listen: true)
        harness.scheduler.advance(by: .seconds(5))
        #expect(harness.changes.last?.health == .ready, "only the 30 s poll runs without a tap")
    }

    @Test func theLiveCheckAsksOnlyForAccessibilityAndDeliversNothingWhileTrusted() {
        let harness = LiveHarness()
        harness.monitor.start()
        harness.monitor.setTapInstalled(true)
        let delivered = harness.changes.count
        let before = harness.probe.accessibilityCheckCount
        harness.scheduler.advance(by: .seconds(10))
        #expect(harness.probe.accessibilityCheckCount - before == 10)
        #expect(harness.changes.count == delivered)
        // PLT-R803: the live check asks for 10 % leeway like every other timer.
        #expect(harness.scheduler.repeatingIntervals.sorted().first == .seconds(1))
    }

    @Test func aRevocationStopsTheLiveCheckUntilTheTapIsBack() {
        let harness = LiveHarness()
        harness.monitor.start()
        harness.monitor.setTapInstalled(true)
        harness.probe.set(trusted: false, post: false, listen: true)
        harness.scheduler.advance(by: .seconds(1))
        harness.monitor.setTapInstalled(false)  // the host removed the tap
        #expect(harness.scheduler.repeatingIntervals == [PermissionMonitor.notReadyInterval])
    }

    /// The main thread's entry points return while a probe call is stuck on the runner.
    @Test func nothingTheMainThreadCallsWaitsForAStalledProbe() async throws {
        let queue = DispatchQueue(label: "test.permissions")
        let harness = LiveHarness(runner: QueueRunner(queue: queue))
        harness.monitor.start()
        queue.sync {}
        harness.probe.holdAccessibilityChecks()
        let monitor = harness.monitor
        let elapsed = await MainActor.run { () -> TimeInterval in
            let started = Date()
            monitor.requestCheck()  // the runner is now stuck in the probe
            _ = monitor.latest
            monitor.setTapInstalled(true)
            monitor.setFastPolling(true)
            monitor.setTapUnavailable(true)
            monitor.requestCheck()
            return Date().timeIntervalSince(started)
        }
        #expect(elapsed < 0.5, "the main thread waited \(elapsed) s for a stalled probe")
        #expect(harness.probe.accessibilityChecksOnMainThread == 0)
        harness.probe.openAccessibilityGate()
        queue.sync {}
        #expect(harness.monitor.latest?.health == .ready)
    }

    @Test func requestCheckRunsTheProbeOnTheRunnerAndThenCallsBack() async throws {
        let queue = DispatchQueue(label: "test.permissions")
        let harness = LiveHarness(trusted: false, runner: QueueRunner(queue: queue))
        let answered = Recorder<PermissionStatus>()
        let monitor = harness.monitor
        await MainActor.run { monitor.requestCheck { answered.append($0) } }
        queue.sync {}
        #expect(harness.probe.accessibilityChecksOnMainThread == 0)
        #expect(answered.last?.health == .noPermission)
    }

    /// While a probe call stalls, the 1 s live check, the polls and every request queue at most one full check and
    /// one live check behind it; every request still gets an answer read after it was made.
    @Test func checksQueuedBehindAStalledProbeCoalesce() async throws {
        let queue = DispatchQueue(label: "test.permissions")
        let harness = LiveHarness(runner: QueueRunner(queue: queue))
        harness.monitor.start()
        harness.monitor.setTapInstalled(true)
        queue.sync {}
        harness.probe.holdAccessibilityChecks()
        let answered = Recorder<PermissionStatus>()
        let entered = harness.probe.accessibilityCheckCount
        harness.monitor.requestCheck { answered.append($0) }  // the runner is now stuck in this one
        for _ in 0..<1_000 where harness.probe.accessibilityCheckCount == entered {
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<50 { harness.monitor.requestCheck { answered.append($0) } }
        harness.scheduler.advance(by: .seconds(60))  // 60 live checks and two 30 s polls fire meanwhile
        let before = harness.probe.accessibilityCheckCount
        harness.probe.openAccessibilityGate()
        queue.sync {}
        #expect(answered.count == 51)
        #expect(harness.probe.accessibilityCheckCount - before <= 2, "one full and one live check ran after the stall")
    }

    /// The runner's answer gates re-enabling the tap after a system disable (PLT-R330), so it is not starved behind
    /// background work while the user types.
    @Test func theProductionRunnerIsUserInitiated() {
        #expect(QueuePermissionCheckRunner.production(label: "test.permissions").queue.qos == .userInitiated)
    }
}
