// SPDX-License-Identifier: GPL-3.0-or-later
//
// W3-A: the integration hooks against the whole input host under fakes (HostRig: real tap thread with a fake
// handle, real pipeline and engine). The two automated QA-R11 scenarios of docs/runbooks/integration-suite.md
// section 6 run here end to end: a tap timeout after "duye" resets the engine, so "etj" becomes "ẹt"
// ("duyeẹt"); revoking Accessibility after "viee" fails open, so "tj" passes untouched ("viêtj").

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite("Integration hook actions on the host")
@MainActor
struct HostHookActionsTests {
    /// A wait that drains the rig's manual main hop and runs its step-by-step worker between short sleeps, so the
    /// tap thread gets to run the performed block (the real build sleeps 10 ms steps, the main queue drains itself
    /// and the worker thread handles the recovery's flush at once).
    private func drainingWait(_ rig: HostRig) -> HookConditionWait {
        HookConditionWait(timeout: .seconds(5), step: .milliseconds(1)) { step in
            try? await Task.sleep(nanoseconds: step.unsignedNanoseconds)
            await MainActor.run {
                rig.controller.drainMainOutbox()
                rig.settle()
                rig.controller.worker.runUntilIdle()
            }
        }
    }

    /// Blocks the calling thread (not the tap thread) until the tap thread signalled, at most 5 s.
    nonisolated private static func waited(for semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    /// Keys typed while no tap is installed reach the field unchanged (PLT-R730 fail-open removed the tap).
    private func typeWithoutTap(_ text: String, _ rig: HostRig) {
        for character in text {
            guard let (code, flags) = HostRig.key(producing: character, in: rig.layout) else {
                Issue.record("no key produces \(character)")
                continue
            }
            let event = RawKeyEvent(
                kind: .keyDown, keyCode: code, flags: flags, autorepeat: false,
                keyboardType: PipelineFixtures.keyboardType, unicode: .empty, userData: 0, receivedAt: MachClock().now()
            )
            rig.field.apply(PipelineHarnessEvents.record(event), layout: rig.layout)
        }
    }

    private func actions(
        _ rig: HostRig, probe: LatencyProbeOutcome = .unavailable, updater: Bool = true
    ) throws -> InputHostHookActions {
        InputHostHookActions(
            host: rig.controller, metrics: rig.metrics, instruments: try #require(rig.instruments),
            processIdentifier: 4_321, wait: drainingWait(rig), latencyProbe: { _ in probe }, updateCheck: { updater })
    }

    /// QA-R11 tap disable and recovery: the engine starts a new word after the recovery.
    @Test func aTapTimeoutMidWordResetsTheEngine_QA_R11() async throws {
        let rig = HostRig(hooks: true)
        await rig.start()
        defer { rig.stop() }
        rig.type("duye")
        let hooks = try actions(rig)
        #expect(await hooks.simulateTapTimeout() == .done)
        rig.routeToCurrentTap()
        rig.type("etj")
        #expect(rig.field.text == "duye\u{1EB9}t")  // "duyeẹt", not "duyệt"
        let state = await hooks.state()
        #expect(state.tapRecoveries == 1 && state.engineResetsAfterTapRecovery == 1)
        #expect(state.state == .ready && state.mode == .vietnamese && state.processIdentifier == 4_321)
        #expect(state.metrics.tapTimeouts == 1)
        #expect(rig.liveHandles.count == 1 && rig.liveHandles[0].isEnabled, "the same tap, re-enabled")
    }

    /// The simulated timeout disables the tap first, as macOS does, and is delivered on the tap thread.
    @Test func theTimeoutDisablesTheTapBeforeTheCallback() async throws {
        let rig = HostRig(hooks: true)
        await rig.start()
        defer { rig.stop() }
        let instruments = try #require(rig.instruments)
        let handle = try #require(rig.liveHandles.first)
        let delivered = DispatchSemaphore(value: 0)
        #expect(instruments.tapFactory.simulateTimeout { delivered.signal() })
        #expect(Self.waited(for: delivered))
        #expect(handle.enableCalls.last == false && !handle.isEnabled)
        rig.controller.drainMainOutbox()
        rig.settle()
        #expect(handle.enableCalls.last == true && handle.isEnabled)
        #expect(rig.controller.counters.tapRecoveryCount == 1)
    }

    /// QA-R11 permission revoked mid-session (PLT-R730): keys pass untouched after the revocation; restoring it
    /// re-creates the tap without a relaunch (7.3).
    @Test func revokingAccessibilityFailsOpenAndRestoringRecovers_PLT_R730() async throws {
        let rig = HostRig(hooks: true)
        await rig.start()
        defer { rig.stop() }
        rig.type("viee")
        #expect(rig.field.text == "vi\u{EA}")
        let hooks = try actions(rig)
        #expect(await hooks.setAccessibilityRevoked(true) == .done)
        let revoked = await hooks.state()
        #expect(revoked.passesKeysThrough)
        #expect(rig.liveHandles.isEmpty, "PLT-R730: the tap is removed")
        rig.echoLoop.route.set(nil, userInfo: 0)
        typeWithoutTap("tj", rig)
        #expect(rig.field.text == "vi\u{EA}tj")  // "viêtj"
        #expect(await hooks.simulateTapTimeout() == .unavailable, "no tap to time out while failed open")
        #expect(await hooks.setAccessibilityRevoked(false) == .done)
        #expect(await hooks.state().state == .ready)
        #expect(rig.liveHandles.count == 1)
        #expect(rig.instruments?.permissions.isRevoked == false)
    }

    @Test func resetMetricsProbeAndUpdateCheck() async throws {
        let rig = HostRig(hooks: true)
        await rig.start()
        defer { rig.stop() }
        rig.metrics.decideToPosted.record(nanoseconds: 2_000_000)
        rig.metrics.flushes.increment()
        let probe = LatencyProbeResult(ranAt: Date(timeIntervalSince1970: 0), results: [])
        let hooks = try actions(rig, probe: .result(probe), updater: false)
        await hooks.resetMetrics()
        #expect(rig.metrics.snapshot() == PlatformMetrics().snapshot())
        #expect(await hooks.runLatencyProbe(.burst) == .result(probe))
        #expect(await hooks.checkForUpdates() == .unavailable)
        let withUpdater = try actions(rig)
        #expect(await withUpdater.checkForUpdates() == .done)
    }

    /// A host that never reaches the expected state answers `timedOut` (the server's `busy`), not a false `done`.
    @Test func aStuckHostTimesOut() async throws {
        let rig = HostRig(hooks: true)
        await rig.start()
        defer { rig.stop() }
        let hooks = InputHostHookActions(
            host: rig.controller, metrics: rig.metrics, instruments: try #require(rig.instruments),
            wait: HookConditionWait(timeout: .milliseconds(3), step: .milliseconds(1)) { _ in },
            latencyProbe: { _ in .unavailable }, updateCheck: { true })
        #expect(await hooks.simulateTapTimeout() == .timedOut, "the main hop is never drained")
        #expect(await hooks.state().processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }
}

@Suite struct RevocablePermissionProbeTests {
    @Test func revocationDeniesAccessibilityAndPostingOnly() {
        let base = FakePermissionProbe()
        let probe = RevocablePermissionProbe(base: base)
        #expect(probe.isAccessibilityTrusted() && probe.canPostEvents() && probe.canListenToEvents())
        probe.setRevoked(true)
        #expect(!probe.isAccessibilityTrusted() && !probe.canPostEvents() && !probe.requestPostEventAccess())
        #expect(probe.canListenToEvents() == base.canListenToEvents())
        #expect(probe.signingIdentityDigest() == base.signingIdentityDigest())
        probe.setRevoked(false)
        #expect(probe.isAccessibilityTrusted() && probe.canPostEvents())
    }

    /// PLT-R702, PLT-R731: the live Input Monitoring check reaches the real probe, revoked or not (revoking
    /// Accessibility does not touch Input Monitoring). The protocol's default would answer with the launch-time
    /// preflight, which in production never sees a grant made after launch, so onboarding would stay on
    /// `listenEventRequired` in the INTEGRATION_HOOKS build after the user turned Input Monitoring on.
    @Test func theLiveInputMonitoringCheckIsForwarded() {
        let base = FakePermissionProbe(trusted: true, post: true, listen: false)
        base.setLiveListen(true)
        let probe = RevocablePermissionProbe(base: base)
        #expect(!probe.canListenToEvents(), "the launch-time preflight still says no")
        #expect(probe.canListenToEventsNow())
        #expect(base.liveListenCheckCount == 1)
        probe.setRevoked(true)
        #expect(probe.canListenToEventsNow())
        base.setLiveListen(false)
        #expect(!probe.canListenToEventsNow())
        #expect(base.liveListenCheckCount == 3)
    }

    @Test func aFactoryWithoutATapCannotTimeOut() {
        let factory = TimeoutSimulatingTapFactory(base: FakeEventTapFactory(failCreation: true))
        #expect(!factory.simulateTimeout())
    }
}
