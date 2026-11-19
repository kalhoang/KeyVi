// SPDX-License-Identifier: GPL-3.0-or-later
//
// The typo correction switch and the never-correct list in the tap's settings snapshot (ENG-R1118, ENG-R1119, PRD-R27,
// PRD-R80; Review Focus 6 of the 1.1.0 plan). D30, D4 and the on or off state of D8 are engine inputs, so a change
// rebuilds the catalog and bumps its revision; the rule's `englishRestore` and `restoreHotkey` are catalog variants.
// Rebinding the restore key to another key is not an engine input: the word being typed is kept. The never-correct
// list is per user, not per app: a focus change never republishes for it. Bundle IDs below are test fixtures.

import AppModel
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private let editor = BundleKey(rawValue: "com.example.editor")!
private let chat = BundleKey(rawValue: "com.example.chat")!

private func makePublisher() -> (TapSettingsPublisher, SnapshotCell<TapSettingsSnapshot>) {
    let cell = SnapshotCell(InputHostController.placeholderSettings, epoch: ReaderEpoch())
    return (TapSettingsPublisher(cell: cell, logger: RecordingLogger(), loadBundled: { .empty }), cell)
}

private func settingsState(_ change: (inout UserSettings) -> Void = { _ in }) -> SettingsState {
    var user = UserSettings()
    change(&user)
    return SettingsState(user: user, macros: [])
}

/// The variants whose rule allows the correction: English restore and the restore key on.
private let correctingVariants = EngineVariant.catalogOrder.filter { $0.englishRestore && $0.restoreHotkey }

private func corrects(_ snapshot: TapSettingsSnapshot, _ variant: EngineVariant) -> Bool {
    snapshot.engines.engine(for: variant).configuration.typoCorrection
}

extension TapSettingsPublisherTests {
    /// The shipped defaults (D30 on, D4 on, D8 Escape) correct in exactly the variants whose rule allows it.
    @Test func theDefaultsCorrectWhereTheRuleAllowsIt_ENGR1119() {
        let (publisher, _) = makePublisher()
        let snapshot = publisher.publish(settingsState()).snapshot
        for variant in EngineVariant.catalogOrder {
            #expect(corrects(snapshot, variant) == (variant.englishRestore && variant.restoreHotkey))
        }
        #expect(!correctingVariants.isEmpty)
    }

    @Test func turningD30OffRebuildsWithTypoCorrectionOff() {
        expectRebuildWithTheSwitchOff { $0.typoCorrection = .set(false) }
    }

    @Test func turningD4OffRebuildsWithTypoCorrectionOff() {
        expectRebuildWithTheSwitchOff { $0.englishRestore = .set(false) }
    }

    /// Row S66 of 13.12 and PRD-R80: with D8 off no key can undo a correction, so none is made.
    @Test func turningTheRestoreKeyOffRebuildsWithTypoCorrectionOff() {
        expectRebuildWithTheSwitchOff { $0.restoreHotkey = .set(nil) }
    }

    /// PRD-R27: D8's binding is not an engine input; only its on or off state is.
    @Test func rebindingTheRestoreKeyKeepsTheRevision() {
        let (publisher, _) = makePublisher()
        let first = publisher.publish(settingsState())
        let f5 = HotkeyBinding.key(KeyCode(rawValue: Key.f5))
        let rebound = publisher.publish(settingsState { $0.restoreHotkey = .set(f5) })
        #expect(!rebound.rebuiltEngines)
        #expect(rebound.snapshot.engines.revision == first.snapshot.engines.revision)
        #expect(rebound.snapshot.restoreHotkey == f5)
        #expect(correctingVariants.allSatisfy { corrects(rebound.snapshot, $0) })
    }

    @Test func aChangedNeverCorrectListRebuildsTheCatalogWithANewRevision() {
        let (publisher, _) = makePublisher()
        let first = publisher.publish(settingsState())
        let learned = publisher.publish(settingsState { $0.neverCorrect = ["androdi"] })
        #expect(learned.rebuiltEngines)
        #expect(learned.snapshot.engines.revision != first.snapshot.engines.revision)
        for variant in EngineVariant.catalogOrder {
            #expect(learned.snapshot.engines.engine(for: variant).resources.userNeverCorrect.contains("androdi"))
        }
    }

    /// ENG-R1118: the list applies in every app. A focus change publishes only when the app's learned keep lists
    /// differ (ENG-R862), never for the never-correct list, and whatever it publishes still carries the list.
    @Test func aNeverCorrectEntryLearnedInOneAppReachesEveryApp() {
        let (publisher, cell) = makePublisher()
        let lists: (inout UserSettings) -> Void = {
            $0.neverCorrect = ["androdi"]
            $0.learn("tar", in: .keepAsTyped, app: editor)
        }
        publisher.publish(settingsState(lists))
        #expect(publisher.focusChanged(to: chat) == nil)
        let inEditor = publisher.focusChanged(to: editor)
        #expect(inEditor != nil)
        for snapshot in [cell.load(), inEditor?.snapshot].compactMap({ $0 }) {
            for variant in EngineVariant.catalogOrder {
                #expect(snapshot.engines.engine(for: variant).resources.userNeverCorrect.contains("androdi"))
            }
        }
        // Learned while typing in the editor, it reaches the chat app too.
        publisher.publish(
            settingsState {
                lists(&$0)
                $0.neverCorrect.insert("gramar")
            })
        _ = publisher.focusChanged(to: chat)
        #expect(cell.load().engines.engine(for: .default).resources.userNeverCorrect.contains("gramar"))
    }

    /// Publishes the defaults, then `change`: the catalog is rebuilt with a new revision and no engine corrects; back
    /// to the defaults rebuilds again with the correction on where the rule allows it.
    private func expectRebuildWithTheSwitchOff(
        _ change: (inout UserSettings) -> Void, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let (publisher, _) = makePublisher()
        let first = publisher.publish(settingsState())
        #expect(correctingVariants.allSatisfy { corrects(first.snapshot, $0) }, sourceLocation: sourceLocation)
        let off = publisher.publish(settingsState(change))
        #expect(off.rebuiltEngines, sourceLocation: sourceLocation)
        #expect(off.snapshot.engines.revision != first.snapshot.engines.revision, sourceLocation: sourceLocation)
        #expect(
            EngineVariant.catalogOrder.allSatisfy { !corrects(off.snapshot, $0) }, sourceLocation: sourceLocation)
        let on = publisher.publish(settingsState())
        #expect(on.rebuiltEngines, sourceLocation: sourceLocation)
        #expect(correctingVariants.allSatisfy { corrects(on.snapshot, $0) }, sourceLocation: sourceLocation)
    }
}
