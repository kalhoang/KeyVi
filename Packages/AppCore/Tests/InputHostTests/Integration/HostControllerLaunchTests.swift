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

    @Test func settingsBeforeStartAreOnlyRecorded() async {
        let rig = HostRig()
        defer { rig.stop() }
        var user = UserSettings()
        user.typingMethod = .set(.vni)
        rig.controller.apply(settings: SettingsState(user: user))
        rig.utility.sync {}
        #expect(rig.controller.channels.snapshots.settings.load().generation == 0, "nothing published before start")
        #expect(rig.tapFactory.handles.isEmpty)
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

    /// PLT-R332, W1-F2 single retry timer: a fire whose hop to main runs after the retry was rescheduled is stale;
    /// it neither retries nor drops the newer timer.
    @Test func aStaleRetryFireKeepsTheRescheduledTimer_PLT_R332() async {
        let rig = HostRig()
        rig.tapFactory.setFailCreation(true)
        await rig.start()
        defer { rig.stop() }
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        rig.scheduler.advance(by: .seconds(1))  // fires; the hop to main is still queued
        rig.controller.scheduleRetry(after: .seconds(5))
        rig.settle()
        #expect(rig.tapFactory.requestedMasks.count == 1, "the stale fire does not retry")
        #expect(rig.controller.retryTimer != nil, "the newer timer is kept")
        rig.tapFactory.setFailCreation(false)
        rig.scheduler.advance(by: .seconds(5))
        rig.settle()
        #expect(rig.tapFactory.requestedMasks.count == 2)
        #expect(rig.lifecyclePhase == .running)
    }

    /// ADR 0309, PLT-R302: a removed tap thread that has not left its run loop blocks the next tap; creation
    /// fails open and the backoff retry creates the tap once the old thread is gone.
    @Test func aTapThreadThatHasNotExitedBlocksTheNextTapUntilTheRetry_PLT_R302() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.exitGate.isHeld = true
        rig.permissions.set(trusted: false, post: false, listen: false)
        _ = rig.controller.refreshPermissions()
        rig.settle()
        #expect(rig.liveHandles.isEmpty)
        rig.permissions.set(trusted: true, post: true, listen: true)
        _ = rig.controller.refreshPermissions()
        rig.settle()
        #expect(rig.lifecyclePhase == .failOpen(.tapUnavailable))
        #expect(rig.tapFactory.handles.count == 1, "no second tap while the first thread may still run")
        rig.scheduler.advance(by: .seconds(1))
        rig.settle()
        #expect(rig.tapFactory.handles.count == 1, "still held: the retry fails open again")
        rig.exitGate.isHeld = false
        rig.scheduler.advance(by: .seconds(2))
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
        #expect(rig.metrics.watchdogTrips.value == 1, "the soak gate counts trips (8.1 M2)")
        rig.controller.feed(.callbackExited)
        #expect(rig.lifecyclePhase == .running)
        #expect(handle.isEnabled)
        #expect(rig.liveHandles.count == 1, "ADR 0309: the same tap, never a second one")
    }

    /// PLT-R306, PLT-R323, ADR 0311: jobs posted while the watchdog held the tap disabled (the flush replays
    /// included) never echo. The returned callback re-enables the same tap, and the next key must not mistake
    /// those missing echoes for broken posting (which would remove the tap for 30 s).
    @Test func jobsPostedAroundAWatchdogTripDoNotBreakPosting_PLT_R306() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let route = try #require(rig.echoLoop.route.current)
        let table = PipelineFixtures.qwertyTable()
        func press(_ character: Character) throws {
            let (code, flags) = try #require(HostRig.key(producing: character, in: table))
            for kind in [RawKeyEvent.Kind.keyDown, .keyUp] {
                let event = RawKeyEvent(
                    kind: kind, keyCode: code, flags: flags, autorepeat: false,
                    keyboardType: PipelineFixtures.keyboardType, unicode: .empty, userData: 0,
                    receivedAt: MachClock().now())
                _ = HostRig.deliverOnTap(event, handle: route.handle, userInfo: route.userInfo)
                rig.controller.worker.runUntilIdle()
            }
        }
        // The callback is stuck: what the worker posts from now on bypasses the tap.
        rig.echoLoop.route.set(nil, userInfo: 0)
        for character in "aasf" { try press(character) }  // three edits, each waiting for its echo
        rig.controller.feed(.watchdogTripped(.callbackOverLimit(microseconds: 300_000)))
        rig.controller.worker.runUntilIdle()  // the trip's flush
        try await Task.sleep(nanoseconds: 250_000_000)  // the stall outlasts the 200 ms echo timeout
        rig.controller.feed(.callbackExited)
        rig.echoLoop.route.set(route.handle, userInfo: route.userInfo)
        rig.type("d")
        rig.settle()
        #expect(!rig.controller.channels.feedback.isPostingBroken)
        #expect(rig.metrics.echoLosses.value == 0)
        #expect(rig.lifecyclePhase == .running)
        #expect(rig.liveHandles.count == 1)
    }

    /// PLT-R331: a permission change is one of the watchdog's check points, so a tap the system left disabled
    /// while the status stayed ready is re-enabled at once, not at the next 5 s tick.
    @Test func permissionChangeChecksTheTapAtOnce_PLT_R331() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let handle = try #require(rig.liveHandles.first)
        handle.setEnabled(false)  // disabled by the system during the change
        rig.permissions.set(trusted: true, post: true, listen: false)  // Input Monitoring off, still ready
        _ = rig.controller.permissionMonitor?.checkNow()
        rig.settle()
        #expect(rig.controller.latestPermissions?.listenEvent == .denied)
        #expect(rig.lifecyclePhase == .running)
        #expect(handle.isEnabled, "PLT-R330 step 1 ran without waiting for the 5 s tick")
    }

    /// PLT-R802: the controller hands its signposts to every tap callback context (and to the worker and the
    /// focus tracker, built from the same dependencies).
    @Test func signpostsReachTheTapCallback_PLT_R802() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let context = try #require(rig.contexts.last)
        #expect(context.signposts != nil)
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

    /// PLT-R1205 steps 3-5: while the guided test types, the host passes every key unchanged, shows the pause,
    /// and returns to typing Vietnamese only after the last of nested calls; per-app memory and the manual mode
    /// stay as they were (no mode change event, no memory write).
    @Test func diagnosticsPassThroughPassesKeysAndNests_PLT_R1205() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.type("vieetj ")
        await rig.memoryRecorded()
        let memoryBefore = await rig.store.store.state.appModes
        let resetsBefore = rig.controller.channels.feedback.compositionResetCount
        rig.controller.setDiagnosticsPassThrough(true)
        rig.controller.setDiagnosticsPassThrough(true)
        rig.settle()
        #expect(rig.controller.channels.snapshots.lifecycle.load().diagnosticsPassThrough)
        #expect(rig.controller.state == .paused(.diagnosticsTest))
        #expect(rig.controller.channels.feedback.compositionResetCount == resetsBefore + 1, "one reset on entry")
        let verdicts = rig.type("dduwowngf ")
        #expect(verdicts.allSatisfy { $0 == .pass })
        #expect(rig.field.text == "việt dduwowngf ", "nothing typed during the test is transformed")
        rig.controller.setDiagnosticsPassThrough(false)
        rig.settle()
        #expect(rig.controller.state == .paused(.diagnosticsTest), "still inside the outer call")
        rig.controller.setDiagnosticsPassThrough(false)
        rig.settle()
        #expect(rig.controller.state == .ready(.vietnamese))
        #expect(rig.controller.channels.feedback.compositionResetCount == resetsBefore + 2, "one reset on exit")
        rig.type("ddi")
        #expect(rig.field.text == "việt dduwowngf đi")
        #expect(!rig.events.contains { if case .modeChanged = $0 { true } else { false } })
        #expect(rig.controller.currentFocus().mode == .vietnamese, "the manual mode is unchanged")
        await rig.memoryRecorded()
        #expect(await rig.store.store.state.appModes == memoryBefore, "nothing written to per-app memory")
    }

    /// PLT-R1205 step 3 with the real pipeline: the runner shares the launch's marker, so its keys and edits reach
    /// the field exactly as posted while the pass-through is on (the engine would otherwise transform "dd" again).
    @Test func guidedTestRunnerTypesThroughThePassThrough_PLT_R1205() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let runner = rig.controller.makeGuidedTestRunner()
        let field = FieldHandle(pid: HostRig.editorPID, token: 1, element: nil)
        rig.controller.setDiagnosticsPassThrough(true)
        rig.settle()
        let result = await runner.run(GuidedTestCandidate(plan: .default), field: field)
        rig.controller.setDiagnosticsPassThrough(false)
        rig.settle()
        #expect(result == .passedByReadback)
        #expect(rig.field.text.isEmpty, "the canary was removed")
        #expect(rig.metrics.snapshot().callbackDuration.count == 0, "probe events stay out of user metrics")
        #expect(rig.controller.state == .ready(.vietnamese))
    }

    /// PLT-R373: with the binding on, the selected layout decides the mode: switching from the VI-bound layout
    /// to the EN-bound one passes keys and the menu shows English; switching back returns to Vietnamese.
    @Test func layoutBindingDecidesTheMode_PLT_R373() async throws {
        let us = InputSourceInfo(
            id: try #require(InputSourceID(rawValue: "com.apple.keylayout.US")), kind: .asciiLayout,
            localizedName: "U.S.", languages: ["en"], isBuiltInVietnamese: false)
        let rig = HostRig(
            source: HostRig.abc,
            layoutData: [
                HostRig.abc.id: KeyboardLayoutData(source: HostRig.abc.id, uchr: Data()),
                us.id: KeyboardLayoutData(source: us.id, uchr: Data()),
            ])
        _ = await rig.store.store.load()
        let binding = LayoutModeBinding(enabled: true, vietnamese: [HostRig.abc.id], english: [us.id])
        await rig.store.store.updateSettings { $0.layoutBinding = .set(binding) }
        await rig.start(preloaded: true)
        defer { rig.stop() }
        rig.type("aa")
        #expect(rig.field.text == "â")
        rig.inputSources.select(us)
        rig.settle()
        #expect(rig.controller.state == .ready(.english))
        rig.type(" aa")
        #expect(rig.field.text == "â aa")
        rig.inputSources.select(HostRig.abc)
        rig.settle()
        #expect(rig.controller.state == .ready(.vietnamese))
        rig.type(" aa")
        #expect(rig.field.text == "â aa â")
    }

    /// PLT-R405, PLT-R373: the Diagnostics window keeps one runner for the process lifetime, so the canary's key
    /// codes come from the layout current when a run starts, not when the runner was made. After a switch from
    /// ABC to AZERTY the `a` key moves; a stale table would type `q` and fail every readback.
    @Test func guidedTestRunnerReadsTheLayoutAtRunTime_PLT_R405() async throws {
        let french = InputSourceInfo(
            id: try #require(InputSourceID(rawValue: "com.apple.keylayout.French")), kind: .asciiLayout,
            localizedName: "French", languages: ["fr"], isBuiltInVietnamese: false)
        let azerty = PipelineFixtures.azertyTable()
        let builder = PerSourceLayoutBuilder(tables: [
            HostRig.abc.id: PipelineFixtures.qwertyTable(), french.id: azerty,
        ])
        let rig = HostRig(
            source: HostRig.abc,
            layoutData: [
                HostRig.abc.id: KeyboardLayoutData(source: HostRig.abc.id, uchr: Data()),
                french.id: KeyboardLayoutData(source: french.id, uchr: Data()),
            ], builder: builder)
        await rig.start()
        defer { rig.stop() }
        let runner = rig.controller.makeGuidedTestRunner()
        rig.inputSources.select(french)
        rig.settle()
        #expect(rig.controller.currentLayoutTable()?.keyCode(producing: "a") == azerty.keyCode(producing: "a"))
        rig.echoLoop.layout.withLock { $0 = azerty }
        let field = FieldHandle(pid: HostRig.editorPID, token: 1, element: nil)
        let postedBefore = rig.poster.posted.count
        rig.controller.setDiagnosticsPassThrough(true)
        rig.settle()
        let result = await runner.run(GuidedTestCandidate(plan: .default), field: field)
        rig.controller.setDiagnosticsPassThrough(false)
        rig.settle()
        #expect(result == .passedByReadback)
        let literalA = rig.poster.posted.dropFirst(postedBefore).compactMap { posted -> KeyCode? in
            guard case .synthetic(let event, _) = posted, event.isKeyDown, event.unicode == InlineUTF16("a") else {
                return nil
            }
            return event.keyCode
        }
        #expect(!literalA.isEmpty)
        #expect(literalA.allSatisfy { $0 == azerty.keyCode(producing: "a") }, "the AZERTY `a` key, not QWERTY's")
    }

    @Test func latencyProbeDriverIsCreatedForThisLaunch_PLT_R810() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let driver = rig.controller.makeLatencyProbeDriver()
        #expect(driver.marker == rig.controller.channels.marker)
    }

    /// The Settings window's recorder and layout binding read the host's layout table and enabled sources
    /// (PLT-R360, PLT-R373) through these queries, never per render from TIS.
    @Test func layoutAndEnabledSourcesComeFromTheHost() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let table = rig.controller.currentLayoutTable()
        #expect(table?.source == rig.controller.channels.snapshots.inputSource.load().table?.source)
        #expect(table?.source == HostRig.abc.id)
        #expect(rig.controller.enabledInputSources() == rig.inputSources.enabledSources())
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
