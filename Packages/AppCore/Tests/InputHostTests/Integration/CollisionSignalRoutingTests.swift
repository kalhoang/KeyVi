// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R862 amendment and ENG-R864 to ENG-R866 in the host (decision of the product owner, 15/11/2026): signals for
// words of the bundled collision list feed the learned memory, per user across apps, and never the per-app lists;
// other words still go to the per-app lists. Signals are drained on main and recorded on the utility queue, never in
// a secure field, an app without English restore, under secure input or with D28 off (PLT-R914); a new vote reaches
// the engines as a new memory revision (ENG-R865). The words are never logged. Bundled data (`as` is an ambiguity
// row, `cos` a collision-supplement word); bundle IDs are fixtures (PLT-R501).

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

private func strong(_ word: String, _ context: CollisionContext = .afterVietnamese) -> CollisionSignal {
    CollisionSignal(word: word, context: context, side: .vietnamese, strength: .strong)
}

@Suite("Collision signal routing (ENG-R862, ENG-R864)")
struct CollisionLearningTrackerTests {
    /// The ENG-R862 amendment: a collision word never becomes a per-app list entry; other words still do.
    @Test func collisionWordsNeverReachThePerAppLists() {
        var tracker = LearningTracker()
        let words: CollisionVocabulary = ["as", "cos"]
        for _ in 0..<3 {
            #expect(tracker.note(.preferredVietnamese(raw: "as"), in: editor, collisionWords: words) == nil)
            #expect(tracker.note(.preferredRaw(raw: "Cos"), in: editor, collisionWords: words) == nil)
        }
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor, collisionWords: words) == nil)
        #expect(tracker.note(.preferredRaw(raw: "tar"), in: editor, collisionWords: words)?.rawKeys == "tar")
    }

    @Test func storeAndEngineVocabulariesMap() {
        let signals = CollisionMemoryBridge.signals([
            CollisionSignal(word: "as", context: .sentenceStart, side: .english, strength: .weak)
        ])
        #expect(
            signals == [CollisionMemorySignal(word: "as", context: .sentenceStart, side: .english, strength: .weak)])
        let snapshot = CollisionMemoryBridge.snapshot([
            CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .conflict),
            CollisionMemoryVote(word: "as", context: nil, choice: .vietnamese),
            CollisionMemoryVote(word: "car", context: nil, choice: .english),
        ])
        #expect(snapshot.vote(word: "as", context: .afterVietnamese) == nil, "a class conflict hides any-context")
        #expect(snapshot.vote(word: "as", context: .afterEnglish) == .vietnamese)
        #expect(snapshot.vote(word: "car", context: .sentenceStart) == .english)
    }
}

@Suite("Collision signals through the host (PLT-R914)")
@MainActor
struct HostCollisionSignalTests {
    private func recorded(_ rig: HostRig) -> Int {
        rig.utility.sync {}
        return rig.store.store.collisionMemory.entryCount
    }

    @Test func recordableSignalsReachTheMemoryAndTheEngines() async {
        let rig = HostRig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        let revision = rig.controller.channels.snapshots.settings.load().engines.memoryRevision
        rig.controller.handle(MainNotice.collisionSignals([strong("as"), strong("as")], recordable: true))
        #expect(recorded(rig) == 2, "the class entry and the any-context entry")
        let engines = rig.controller.channels.snapshots.settings.load().engines
        #expect(engines.memoryRevision != revision)
        #expect(
            engines.engine(for: .default).resources.collisionMemory.vote(word: "as", context: .afterVietnamese)
                == .vietnamese)
        #expect(!rig.logger.entries.contains { "\($0.event)".contains("\"as\"") }, "PLT-R901: never logged")
    }

    /// PLT-R914: nothing from a secure field or an app without English restore (`recordable` false), nothing under
    /// secure input, nothing with D28 off, and nothing for a word outside the bundled list.
    @Test func unrecordableSignalsAreDropped() async {
        let rig = HostRig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        rig.controller.handle(MainNotice.collisionSignals([strong("as")], recordable: false))
        #expect(recorded(rig) == 0)
        rig.controller.handle(MainNotice.collisionSignals([strong("qzxwk")], recordable: true))
        #expect(recorded(rig) == 0, "not a word of the bundled collision list")
        rig.controller.channels.snapshots.secureInput.publish(
            SecureInputSnapshot(generation: 1, enabled: true, holder: nil))
        rig.controller.handle(MainNotice.collisionSignals([strong("as")], recordable: true))
        #expect(recorded(rig) == 0)
        rig.controller.channels.snapshots.secureInput.publish(
            SecureInputSnapshot(generation: 2, enabled: false, holder: nil))
        await rig.store.store.updateSettings { $0.learnCollisionChoices = .set(false) }
        rig.controller.apply(settings: await rig.store.store.state)
        rig.controller.handle(MainNotice.collisionSignals([strong("as")], recordable: true))
        #expect(recorded(rig) == 0)
    }

    /// End to end with the real engine: Escape restores `as` against the rules; its strong signal is recorded in the
    /// memory and its learning signal never becomes a per-app entry.
    @Test func aRestoredCollisionWordFeedsTheMemoryNotThePerAppList() async {
        let rig = HostRig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        for _ in 0..<2 {
            _ = rig.type("as")
            _ = rig.send(.keyDown, keyCode: Key.escape)
            _ = rig.send(.keyUp, keyCode: Key.escape)
            _ = rig.type(" ")
        }
        #expect(rig.field.text == "as as ")
        rig.settle()
        #expect(recorded(rig) >= 1)
        #expect(!rig.events.contains { if case .learningProposal = $0 { true } else { false } })
        let user = await rig.store.store.state.user
        #expect(user.learnedWords.isEmpty)
    }

    /// PLT-R914 with PLT-R1006 ("never wipe"): when the bundled lists fail to load there is no collision list to
    /// validate the file against, so the memory is not loaded at all. The file on disk stays byte for byte as it was,
    /// even after a signal and well past the 2 s debounce, and nothing is recorded.
    @Test func aFailedBundledListLeavesTheMemoryFileUntouched() async throws {
        struct BundledListsMissing: Error {}
        let rig = HostRig(loadBundled: { throw BundledListsMissing() })
        let url = SettingsStoreHarness.directory.appendingPathComponent(CollisionMemoryStore.fileName)
        let seeded = Data(
            (#"{"schemaVersion":1,"writtenBy":"0.1.0","entries":[{"word":"as","context":"any","#
                + #""correctionsEnglish":0,"correctionsVietnamese":2,"acceptedEnglish":0,"acceptedVietnamese":0,"#
                + #""classesEnglish":0,"classesVietnamese":2,"decayDay":20770,"lastDay":20770}]}"#).utf8)
        try rig.store.memory.createDirectory(at: SettingsStoreHarness.directory, permissions: .ownerOnlyDirectory)
        try rig.store.memory.writeAtomically(seeded, to: url, permissions: .ownerOnlyFile)
        await rig.start()
        defer { rig.stop() }
        rig.controller.handle(MainNotice.collisionSignals([strong("as")], recordable: true))
        #expect(recorded(rig) == 0)
        await rig.store.advance(by: .seconds(3))
        rig.utility.sync { rig.store.store.collisionMemory.flush() }
        #expect(!rig.store.store.collisionMemory.isLoaded)
        #expect(rig.store.memory.nodes[url.path]?.data == seeded)
    }
}

@Suite("The learned memory reaches the engines (ENG-R865)")
struct CollisionMemoryPublicationTests {
    private static let votes = CollisionMemoryBridge.snapshot([
        CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .vietnamese)
    ])

    private func publisher() -> (TapSettingsPublisher, SnapshotCell<TapSettingsSnapshot>) {
        let cell = SnapshotCell(InputHostController.placeholderSettings, epoch: ReaderEpoch())
        return (TapSettingsPublisher(cell: cell, logger: RecordingLogger(), loadBundled: { .empty }), cell)
    }

    /// A new memory keeps the settings revision and bumps the memory revision, so the tap swaps at a hard boundary.
    @Test func aNewMemoryKeepsTheSettingsRevision() throws {
        let (publisher, cell) = publisher()
        #expect(publisher.collisionMemoryChanged(Self.votes) == nil, "before the first settings publication")
        let first = publisher.publish(SettingsState())
        #expect(first.snapshot.engines.engine(for: .default).resources.collisionMemory == Self.votes)
        let changed = try #require(publisher.collisionMemoryChanged(.empty))
        #expect(changed.snapshot.engines.revision == first.snapshot.engines.revision)
        #expect(changed.snapshot.engines.memoryRevision != first.snapshot.engines.memoryRevision)
        #expect(cell.load().engines.engine(for: .default).resources.collisionMemory.isEmpty)
        #expect(publisher.collisionMemoryChanged(.empty) == nil, "the same memory again")
    }

    /// D28 off: the engines carry the empty snapshot and memory changes publish nothing; D29 is an engine setting.
    @Test func d28OffAndD29() throws {
        let (publisher, cell) = publisher()
        var user = UserSettings()
        user.learnCollisionChoices = .set(false)
        let off = publisher.publish(SettingsState(user: user))
        #expect(publisher.collisionMemoryChanged(Self.votes) == nil)
        #expect(cell.load().engines.engine(for: .default).resources.collisionMemory.isEmpty)
        user.learnCollisionChoices = .unset
        let on = publisher.publish(SettingsState(user: user))
        #expect(on.rebuiltEngines && on.snapshot.engines.revision != off.snapshot.engines.revision)
        #expect(cell.load().engines.engine(for: .default).resources.collisionMemory == Self.votes)
        user.lookaheadRevision = .set(false)
        let noRevision = publisher.publish(SettingsState(user: user))
        #expect(noRevision.rebuiltEngines)
        #expect(!cell.load().engines.engine(for: .default).configuration.lookaheadRevision)
    }
}
