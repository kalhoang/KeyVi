// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Tap -> main notices, focus and secure-input changes as the shell sees them, per-app memory persistence,
// learning, conflicts and the typing-trace gaps (PRD-R10, PRD-R11, PRD-R20, PRD-R23, PLT-R395-R398B,
// PLT-R399, PLT-R905, ENG-R861). Workstream W2-A.

import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

@Suite("Host notices and what the shell sees")
@MainActor
struct HostNoticeTests {
    static let otherPID: Int32 = 5_151

    @Test func hotkeyToggleIsAManualModeChangeAndTheIconFollowsAtOnce_PRD_R12() async throws {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let bundle = try #require(rig.controller.currentFocus().app?.bundle)
        rig.controller.handle(MainNotice.modeToggled(sequence: 99, bundle: bundle, mode: .english))
        #expect(rig.controller.state == .ready(.english), "the tap's own toggle wins until ax applies it")
        #expect(rig.events.contains { if case .modeChanged(.english, true, bundle) = $0 { true } else { false } })
    }

    @Test func aFocusedSecureFieldPausesThroughTheAXNotificationPath_PLT_R387() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.ax.focus(
            pid: HostRig.editorPID,
            attributes: FocusAttributes(
                role: "AXTextField", subrole: "AXSecureTextField", identifier: nil, domClasses: [], editable: true,
                ancestorRoles: [], documentURL: nil, windowTitle: nil),
            notify: .focusedElementChanged)
        rig.settle()
        #expect(rig.controller.state == .paused(.secureField))
    }

    @Test func activationOfAnotherAppIsAFocusChange_PLT_R381() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.processes.add(FakeProcessIdentityProvider.process(pid: Self.otherPID, bundle: "com.example.chat"))
        rig.ax.focus(
            pid: Self.otherPID,
            attributes: FocusAttributes(
                role: "AXTextArea", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
                documentURL: nil, windowTitle: nil),
            notify: nil)
        rig.workspace.send(.applicationActivated(pid: Self.otherPID))
        rig.settle()
        let chat = BundleKey(rawValue: "com.example.chat")
        #expect(rig.controller.currentFocus().app?.bundle == chat)
        #expect(rig.events.contains { if case .focusChanged(chat, _) = $0 { true } else { false } })
    }

    @Test func secureInputPausesNamesTheHolderAndKeyEvidenceResumes_PLT_R398B() async throws {
        let rig = HostRig()
        rig.processes.add(FakeProcessIdentityProvider.process(pid: Self.otherPID, bundle: "com.googlecode.iterm2"))
        await rig.start()
        defer { rig.stop() }
        rig.secureInput.set(enabled: true, holderPID: Self.otherPID)
        let snapshot = rig.controller.refreshSecureInput()
        rig.settle()
        #expect(snapshot.enabled)
        guard case .paused(.secureInput(let holder?)) = rig.controller.state else {
            Issue.record("expected a secure-input pause, got \(rig.controller.state)")
            return
        }
        #expect(holder.hintKey == "iterm2.secureKeyboardEntry", "PLT-R397: the hint comes from the rules data")
        rig.controller.handle(MainNotice.secureInputResumedByKey(generation: snapshot.generation))
        #expect(rig.controller.state == .ready(.vietnamese), "PLT-R398B: resumed without waiting for a poll")
    }

    @Test func menuModeChangeIsPersistedThroughTheStore_PRD_R23() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.setMode(.english, manual: true)
        rig.settle()
        for _ in 0..<20 where await rig.store.store.state.appModes.apps.isEmpty { await Task.yield() }
        let modes = await rig.store.store.state.appModes
        #expect(modes.apps.contains { $0.bundle.rawValue == HostRig.editorBundle })
    }

    @Test func theSecondIdenticalLearningSignalUpdatesTheList_ENG_R861() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.handle(MainNotice.learning(.preferredRaw(raw: "qzxwk")))
        #expect(!rig.events.contains { if case .learningProposal = $0 { true } else { false } })
        rig.controller.handle(MainNotice.learning(.preferredRaw(raw: "qzxwk")))
        #expect(
            rig.events.contains {
                if case .learningProposal(let proposal) = $0 { proposal.rawKeys == "qzxwk" } else { false }
            })
        for _ in 0..<20 where await rig.store.store.state.user.keepAsTyped.isEmpty { await Task.yield() }
        #expect(await rig.store.store.state.user.keepAsTyped == ["qzxwk"])
        #expect(!rig.logger.entries.contains { "\($0.event)".contains("qzxwk") }, "PLT-R901: content is never logged")
    }

    @Test func conflictingInputAppsAreReportedOncePerLaunch_PLT_R399() async throws {
        let rig = HostRig()
        let rules = HostRig.shippedRules
        let conflicting = try #require(rules.document.conflictingInputApps.first)
        rig.processes.add(FakeProcessIdentityProvider.process(pid: Self.otherPID, bundle: conflicting.rawValue))
        await rig.start(rules: rules)
        defer { rig.stop() }
        rig.settle()
        let reports = rig.events.filter { if case .conflictsDetected = $0 { true } else { false } }
        #expect(reports.count == 1)
        #expect(rig.controller.reportContext().conflicts.count == 1)
        rig.controller.reportConflicts(rig.controller.conflicts)
        #expect(rig.events.filter { if case .conflictsDetected = $0 { true } else { false } }.count == 1)
    }

    @Test func reportContextIsMetadataOfTheLiveHost_PLT_R1202() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let context = rig.controller.reportContext()
        #expect(context.state == .ready(.vietnamese))
        #expect(context.tapEnabled)
        #expect(context.permissions.health == .ready)
        #expect(context.focus.app?.bundle.rawValue == HostRig.editorBundle)
        #expect(context.inputSource.source.id == HostRig.abc.id)
    }

    @Test func typingTraceRecordsNothingDuringSecureInput_PLT_R905() async throws {
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/captures", isDirectory: true), fileSystem: InMemoryFileSystem(),
            wallClock: FixedWallClock(), clock: clock, scheduler: ManualScheduler(clock: clock))
        let rig = HostRig(capture: capture)
        await rig.start()
        defer { rig.stop() }
        _ = try capture.start(duration: .seconds(60))
        #expect(capture.isRecording)
        rig.secureInput.set(enabled: true, holderPID: nil)
        _ = rig.controller.refreshSecureInput()
        rig.settle()
        #expect(!capture.isRecording, "gap while secure input is on")
        rig.secureInput.set(enabled: false, holderPID: nil)
        _ = rig.controller.refreshSecureInput()
        rig.settle()
        #expect(capture.isRecording)
        _ = capture.stop()
    }

    @Test func keyboardTypeNoticeReachesTheInputSourceMonitor() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        let before = rig.controller.channels.snapshots.inputSource.load().generation
        rig.controller.handle(MainNotice.keyboardTypeSeen(41))
        rig.settle()
        #expect(rig.controller.channels.snapshots.inputSource.load().generation >= before)
    }

    @Test func tapNoticesArriveThroughTheOutboxSignal() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        _ = rig.controller.channels.outbox.toMain.push(.postingBroken)
        rig.controller.channels.feedback.markPostingBroken()
        rig.controller.channels.outbox.mainSignal.signal()
        for _ in 0..<50 where rig.lifecyclePhase == .running {
            rig.utility.sync {}
            rig.hop.drain()
            await Task.yield()
        }
        #expect(rig.lifecyclePhase == .failOpen(.postingBroken))
    }
}
