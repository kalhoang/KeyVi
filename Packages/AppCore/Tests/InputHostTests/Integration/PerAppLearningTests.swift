// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-app learning in the host (ENG-R861, ENG-R862, decision of 13/11/2026, ADR 0320): two identical signals in the
// same app add the word for that app, and the engines carry the focused app's lists (global entries plus that app's
// learned words, ENG-R851), rebuilt off the tap thread only when the focus moves to an app whose lists differ
// (PLT-R304, PLT-R305). Bundle IDs below are test fixtures (PLT-R501). Workstream W5-B.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private let editor = BundleKey(rawValue: "com.example.editor")!  // HostRig.editorBundle
private let chat = BundleKey(rawValue: "com.example.chat")!

@Suite("Learning from restore toggles, per app (ENG-R861, ENG-R862)")
struct LearningTrackerTests {
    @Test func theSecondIdenticalSignalInTheSameAppProposesForThatApp() {
        var tracker = LearningTracker()
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor) == nil)
        #expect(tracker.note(.preferredVietnamese(raw: "tar"), in: editor) == nil, "a different list is a new signal")
        #expect(
            tracker.note(.preferredRaw(raw: "tar"), in: editor)
                == LearningProposal(list: .keepAsTyped, rawKeys: "tar", app: editor))
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor) == nil, "the count starts over")
        #expect(tracker.note(.preferredRaw(raw: ""), in: editor) == nil)
    }

    @Test func signalsFromDifferentAppsAreCountedSeparately() {
        var tracker = LearningTracker()
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor) == nil)
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: chat) == nil, "one signal in each app is not two")
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: chat)?.app == chat)
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor)?.app == editor)
    }

    @Test func aSignalWithoutAnAppIsNeverLearned() {
        var tracker = LearningTracker()
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: nil) == nil)
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: nil) == nil)
    }

    @Test func pendingSignalsAreBounded() {
        var tracker = LearningTracker()
        for index in 0...LearningTracker.capacity { _ = tracker.note(.preferredRaw(raw: "w\(index)"), in: editor) }
        #expect(tracker.note(.preferredRaw(raw: "w0"), in: editor) == nil, "the oldest pending signal was forgotten")
        #expect(tracker.note(.preferredRaw(raw: "w\(LearningTracker.capacity)"), in: editor) != nil)
    }

    /// The word is stored for its app; the global lists are untouched; in that app the newest choice wins.
    @Test func applyingStoresTheWordForItsApp() {
        var settings = UserSettings()
        settings.keepVietnamese = ["tar"]
        LearningProposal(list: .keepAsTyped, rawKeys: "tar", app: editor).apply(to: &settings)
        #expect(settings.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)])
        #expect(settings.keepVietnamese == ["tar"] && settings.keepAsTyped.isEmpty)
        LearningProposal(list: .keepVietnamese, rawKeys: "mas", app: editor).apply(to: &settings)
        LearningProposal(list: .keepVietnamese, rawKeys: "tar", app: editor).apply(to: &settings)
        #expect(settings.learnedWords == [LearnedWord(list: .keepVietnamese, raw: "mas", app: editor)])
    }
}

private func publisher(logger: RecordingLogger = RecordingLogger())
    -> (TapSettingsPublisher, SnapshotCell<TapSettingsSnapshot>)
{
    let cell = SnapshotCell(InputHostController.placeholderSettings, epoch: ReaderEpoch())
    let publisher = TapSettingsPublisher(cell: cell, logger: logger, loadBundled: { .empty })
    return (publisher, cell)
}

private func state(_ change: (inout UserSettings) -> Void) -> SettingsState {
    var user = UserSettings()
    change(&user)
    return SettingsState(user: user)
}

private func userKeepRaw(_ cell: SnapshotCell<TapSettingsSnapshot>) -> WordSet {
    cell.load().engines.engine(for: .default).resources.userKeepRaw
}

@Suite("The engines carry the focused app's lists (ENG-R851, ENG-R862)")
struct FocusedAppWordListTests {
    private let settings = state {
        $0.keepAsTyped = ["text"]
        $0.learn("tar", in: .keepAsTyped, app: editor)
        $0.learn("text", in: .keepVietnamese, app: chat)
    }

    @Test func aFocusChangeGivesTheEnginesThatAppsLearnedWords() throws {
        let (publisher, cell) = publisher()
        let first = publisher.publish(settings)
        #expect(userKeepRaw(cell).contains("text") && !userKeepRaw(cell).contains("tar"), "no app yet: global only")
        let toEditor = try #require(publisher.focusChanged(to: editor))
        #expect(toEditor.rebuiltEngines)
        #expect(toEditor.snapshot.engines.revision != first.snapshot.engines.revision)
        #expect(userKeepRaw(cell).contains("tar") && userKeepRaw(cell).contains("text"))
        _ = try #require(publisher.focusChanged(to: chat))
        let engine = cell.load().engines.engine(for: .default)
        #expect(!engine.resources.userKeepRaw.contains("tar"), "a word learned in the editor stays there")
        #expect(engine.resources.userKeepVietnamese.contains("text"), "the chat app's own choice wins there")
        #expect(!engine.resources.userKeepRaw.contains("text"))
    }

    /// Switching between apps whose lists are the same publishes nothing, so the word being typed is kept.
    @Test func aFocusChangeWithTheSameListsPublishesNothing() throws {
        let (publisher, cell) = publisher()
        publisher.publish(settings)
        let mail = BundleKey(rawValue: "com.example.mail")!
        #expect(publisher.focusChanged(to: mail) == nil)
        #expect(publisher.focusChanged(to: nil) == nil)
        let generation = cell.load().generation
        _ = try #require(publisher.focusChanged(to: editor))
        #expect(publisher.focusChanged(to: editor) == nil, "the same app again")
        #expect(cell.load().generation == generation + 1)
    }

    /// A settings change after the focus moved keeps the focused app's lists, and a new learned word for that app
    /// reaches the engines with the next publication.
    @Test func settingsChangesKeepTheFocusedAppsLists() {
        let (publisher, cell) = publisher()
        publisher.publish(settings)
        publisher.focusChanged(to: editor)
        var next = settings
        next.user.learn("cos", in: .keepAsTyped, app: editor)
        let published = publisher.publish(SettingsState(user: next.user))
        #expect(published.rebuiltEngines)
        #expect(userKeepRaw(cell).contains("cos") && userKeepRaw(cell).contains("tar"))
        var quieter = next.user
        quieter.soundOnSwitch = .set(true)
        #expect(!publisher.publish(SettingsState(user: quieter)).rebuiltEngines, "PRD-R27: not an engine change")
    }

    /// A focus change reuses the macro table: its problems are still reported but not logged again.
    @Test func aFocusChangeKeepsTheMacroTableAndLogsItsProblemsOnce() throws {
        let logger = RecordingLogger()
        let (publisher, _) = publisher(logger: logger)
        var withMacros = settings
        withMacros.macros = [
            StoredMacro(trigger: "", expansion: "x"), StoredMacro(trigger: "vn", expansion: "Việt Nam"),
        ]
        #expect(publisher.publish(withMacros).macroIssues.count == 1)
        #expect(logger.entries.count == 1)
        let moved = try #require(publisher.focusChanged(to: editor))
        #expect(moved.rebuiltEngines)
        #expect(moved.macroIssues.count == 1)
        #expect(logger.entries.count == 1, "the same macros are not validated or logged again")
    }

    /// Before the first settings publication there is nothing to rebuild.
    @Test func aFocusChangeBeforeTheFirstPublicationOnlyRemembersTheApp() {
        let (publisher, cell) = publisher()
        #expect(publisher.focusChanged(to: editor) == nil)
        publisher.publish(settings)
        #expect(userKeepRaw(cell).contains("tar"), "the first publication uses the remembered app")
    }
}

@Suite("Per-app learning through the host (ENG-R862)")
@MainActor
struct HostPerAppLearningTests {
    @Test func theSecondIdenticalSignalStoresTheWordForItsApp() async {
        let rig = HostRig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.handle(MainNotice.learning(.preferredRaw(raw: "qzxwk"), bundle: editor))
        #expect(!rig.events.contains { if case .learningProposal = $0 { true } else { false } })
        rig.controller.handle(MainNotice.learning(.preferredRaw(raw: "qzxwk"), bundle: editor))
        #expect(
            rig.events.contains {
                if case .learningProposal(let proposal) = $0 {
                    proposal.rawKeys == "qzxwk" && proposal.app == editor
                } else {
                    false
                }
            })
        for _ in 0..<20 where await rig.store.store.state.user.learnedWords.isEmpty { await Task.yield() }
        let user = await rig.store.store.state.user
        #expect(user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "qzxwk", app: editor)])
        #expect(user.keepAsTyped.isEmpty, "learning never adds a global entry")
        #expect(!rig.logger.entries.contains { "\($0.event)".contains("qzxwk") }, "PLT-R901: content is never logged")
    }

    /// ENG-R862, PLT-R304: the tap stamps each learning notice with the app of the focus snapshot it typed into,
    /// so the word belongs to that app even when the focus moved before the main thread drained the outbox.
    /// Through the real tap, engine and resources: `vieejt` restored with Escape and committed, twice.
    @Test func aWordTypedBeforeTheFocusMovesBelongsToTheAppWhereItWasTyped() async {
        let rig = HostRig(realResources: true)
        let chatPID: Int32 = 4_343
        rig.processes.add(FakeProcessIdentityProvider.process(pid: chatPID, bundle: chat.rawValue))
        await rig.start()
        defer { rig.stop() }
        for _ in 0..<2 {
            rig.type("vieejt")
            rig.send(.keyDown, keyCode: Key.escape)
            rig.send(.keyUp, keyCode: Key.escape)
            rig.type(" ")
        }
        #expect(rig.field.text == "vieejt vieejt ")
        // The notices wait in the outbox (the main hop has not run); the chat app takes the focus first.
        rig.ax.focus(
            pid: chatPID,
            attributes: FocusAttributes(
                role: "AXTextArea", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
                documentURL: nil, windowTitle: nil),
            notify: nil)
        rig.workspace.send(.applicationActivated(pid: chatPID))
        rig.settle()
        #expect(rig.controller.currentFocus().app?.bundle == chat)
        let proposals = rig.events.compactMap { if case .learningProposal(let proposal) = $0 { proposal } else { nil } }
        #expect(proposals == [LearningProposal(list: .keepAsTyped, rawKeys: "vieejt", app: editor)])
        for _ in 0..<20 where await rig.store.store.state.user.learnedWords.isEmpty { await Task.yield() }
        let user = await rig.store.store.state.user
        #expect(user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "vieejt", app: editor)])
    }

    /// At launch the engines get the focused app's learned words once focus is known.
    @Test func theFocusedAppsLearnedWordsReachTheTapSnapshot() async {
        let rig = HostRig()
        _ = await rig.store.store.load()
        await rig.store.store.updateSettings { $0.learn("qzxwk", in: .keepAsTyped, app: editor) }
        await rig.start(preloaded: true)
        defer { rig.stop() }
        rig.settle()
        let engine = rig.controller.channels.snapshots.settings.load().engines.engine(for: .default)
        #expect(engine.resources.userKeepRaw.contains("qzxwk"))
    }
}
