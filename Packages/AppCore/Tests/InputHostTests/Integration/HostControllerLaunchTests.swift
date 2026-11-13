// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `InputHostController` under fakes: launch to ready, the HostLifecycle tables performed end to end, the
// retry timer, posting-broken recovery and stop (02-platform.md 2.1, PLT-R302, PLT-R330-R333, PLT-R730,
// PLT-R731, S1). Workstream W2-A.

import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

@Suite("Host controller launch and lifecycle (2.1)")
@MainActor
struct HostControllerLaunchTests {
    @Test func launchWithPermissionsReachesReadyWithOneTap_S1() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.controller.state == .ready(.vietnamese))
        #expect(rig.liveHandles.count == 1, "PLT-R302: exactly one tap")
        #expect(rig.tapFactory.requestedMasks == [.standard])
        #expect(rig.events.contains { if case .stateChanged(.ready) = $0 { true } else { false } })
    }

    @Test func telexWordThroughTheWholeHost() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.type("duyeetj")
        #expect(rig.field.text == "duyệt")
    }
}

@Suite("Host controller performs the HostLifecycle tables (2.1)")
@MainActor
struct HostControllerLifecycleTests {
    @Test func noPermissionAtLaunchThenGrantCreatesTheTapWithoutRelaunch_PLT_R731() async {
        let rig = HostRig(permissions: FakePermissionProbe(trusted: false, post: false, listen: false))
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .noPermission)
        #expect(rig.controller.state == .noPermission)
        #expect(rig.tapFactory.handles.isEmpty, "no tap without permission")
        rig.permissions.set(trusted: true, post: true, listen: true)
        _ = rig.controller.refreshPermissions()
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.liveHandles.count == 1)
        #expect(rig.health.recent(limit: 10).contains { $0.kind == .permissionTransition })
    }

    @Test func tapCreationFailureRetriesOnTheBackoffTimer_PLT_R332() async {
        let rig = HostRig()
        rig.tapFactory.setFailCreation(true)
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        #expect(rig.controller.state == .failOpen(.tapUnavailable))
        rig.scheduler.advance(by: .milliseconds(999))
        rig.settle()
        #expect(rig.tapFactory.requestedMasks.count == 1, "no retry before 1 s")
        rig.scheduler.advance(by: .milliseconds(1))
        rig.settle()
        #expect(rig.tapFactory.requestedMasks.count == 2, "first retry after 1 s")
        rig.tapFactory.setFailCreation(false)
        rig.scheduler.advance(by: .seconds(2))
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.liveHandles.count == 1)
    }

    @Test func revokedPermissionFailsOpenRemovesTheTapAndRegrantRecreatesIt_PLT_R730() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let first = rig.liveHandles.first
        rig.permissions.set(trusted: false, post: false, listen: false)
        _ = rig.controller.refreshPermissions()
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.permissionRevoked))
        #expect(first?.isInvalidated == true, "the tap is removed")
        #expect(rig.liveHandles.isEmpty)
        rig.permissions.set(trusted: true, post: true, listen: true)
        _ = rig.controller.refreshPermissions()
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.tapFactory.handles.count == 2)
        #expect(rig.liveHandles.count == 1, "PLT-R302: never two taps")
    }

    @Test func postingBrokenRetriesAfterThirtySecondsWithAFreshEchoTracker_PLT_R323() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let firstEcho = try #require(rig.controller.session?.echo)
        rig.controller.channels.feedback.markPostingBroken()
        rig.controller.handle(MainNotice.postingBroken)
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.postingBroken))
        #expect(rig.liveHandles.isEmpty)
        #expect(rig.health.recent(limit: 10).contains { $0.kind == .postingBroken })
        rig.scheduler.advance(by: .seconds(30))
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
        #expect(!rig.controller.channels.feedback.isPostingBroken, "W1-F2: cleared before the new tap transforms")
        let secondEcho = try #require(rig.controller.session?.echo)
        #expect(secondEcho !== firstEcho)
        #expect(secondEcho.consecutiveMisses == 0)
        #expect(rig.controller.channels.queue.inFlight == 0)
    }

    @Test func echoMissWithPostAccessRevokedBreaksPostingAtOnce_ADR0311() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.permissions.set(trusted: true, post: false, listen: true)
        rig.controller.handle(MainNotice.echoMissed)
        rig.settle()
        #expect(rig.controller.channels.feedback.isPostingBroken)
        #expect(rig.lifecyclePhase == .failOpen(.postingBroken))
    }

    @Test func systemDisableReenablesFlushesAndWarnsAfterFourInTenMinutes_PLT_R330() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        for index in 0..<4 {
            rig.controller.handle(MainNotice.tapDisabled(byTimeout: index % 2 == 0))
            rig.clock.advance(byMicroseconds: 2_000_000)
        }
        rig.settle()
        #expect(handle.enableCalls.filter { $0 }.count == 4, "PLT-R330 step 1: one re-enable per disable")
        let kinds = rig.health.recent(limit: 20).map(\.kind)
        #expect(kinds.filter { $0 == .tapTimeout }.count == 2)
        #expect(kinds.filter { $0 == .tapDisabledByUserInput }.count == 2)
        #expect(rig.events.contains { if case .tapInstabilityNotice = $0 { true } else { false } })
    }

    @Test func watchdogTripDisablesAndTheReturnedCallbackReenables_PLT_R306() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        rig.controller.feed(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        #expect(rig.lifecyclePhase == .failOpen(.watchdog))
        #expect(handle.isEnabled == false)
        rig.controller.feed(.callbackExited)
        #expect(rig.lifecyclePhase == .running)
        #expect(handle.isEnabled)
        #expect(rig.liveHandles.count == 1, "ADR 0309: the same tap, never a second one")
    }

    @Test func sleepLockAndUserSwitchPauseUntilEveryReasonCleared_PLT_R333() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.workspace.send(.screenLocked)
        rig.workspace.send(.willSleep)
        rig.settle()
        #expect(rig.controller.state == .paused(.sessionInactive))
        rig.workspace.send(.didWake)
        rig.settle()
        #expect(rig.controller.state == .paused(.sessionInactive), "still locked")
        rig.workspace.send(.screenUnlocked)
        rig.settle()
        #expect(rig.controller.state == .ready(.vietnamese))
        rig.workspace.send(.sessionResignedActive)
        rig.settle()
        #expect(rig.lifecyclePhase == .sessionInactive)
        rig.workspace.send(.sessionBecameActive)
        rig.settle()
        #expect(rig.lifecyclePhase == .running)
    }

    @Test func recorderSuspendsHotkeysThroughTheLifecycleSnapshot_PRD_R15() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.setRecorderActive(true)
        #expect(rig.controller.channels.snapshots.lifecycle.load().recorderActive)
        rig.controller.setRecorderActive(false)
        #expect(!rig.controller.channels.snapshots.lifecycle.load().recorderActive)
    }

    @Test func stopRemovesTheTapAndLeavesNothingRunning() async throws {
        let rig = HostRig()
        await rig.start()
        let handle = try #require(rig.liveHandles.first)
        rig.stop()
        #expect(handle.isInvalidated)
        #expect(rig.controller.session == nil)
        rig.controller.start(rules: HostRig.shippedRules, settings: SettingsState())
        #expect(rig.tapFactory.handles.count == 1, "a stopped host never starts again")
    }
}
