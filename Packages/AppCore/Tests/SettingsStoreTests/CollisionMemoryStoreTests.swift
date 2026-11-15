// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R914: collision-memory.json in the settings folder, mode 0600, schema version 1, written two seconds after the
// first change, validated against the bundled list at load, renamed aside when corrupt, never rewritten when a newer
// schema wrote it, deleted by "Xóa tất cả" and by the Typing pane reset; exported and imported with the settings,
// import merging by adding counters (PRD-R72). Virtual time and an in-memory file system.

import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import SettingsStore

private let vocabulary: CollisionVocabulary = ["as", "car", "cos"]

private func count(_ value: JSONValue?) -> Int? {
    guard case .array(let items)? = value else { return nil }
    return items.count
}

private func signal(
    _ word: String, _ context: CollisionMemoryContext = .afterVietnamese, _ side: CollisionMemorySide = .vietnamese,
    strong: Bool = true
) -> CollisionMemorySignal {
    CollisionMemorySignal(word: word, context: context, side: side, strength: strong ? .strong : .weak)
}

/// Collects the votes the store publishes.
private final class VoteRecorder: Sendable {
    private let published = Mutex<[[CollisionMemoryVote]]>([])
    var all: [[CollisionMemoryVote]] { published.withLock { $0 } }
    func record(_ votes: [CollisionMemoryVote]) { published.withLock { $0.append(votes) } }
}

extension SettingsStoreHarness {
    fileprivate var memoryURL: URL { Self.directory.appendingPathComponent(CollisionMemoryStore.fileName) }
    fileprivate var memoryNode: InMemoryFileSystem.Node? { memory.nodes[memoryURL.path] }

    fileprivate func memoryFile() -> [String: JSONValue]? {
        guard let data = memoryNode?.data else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    fileprivate func seedMemory(_ text: String) {
        try? memory.createDirectory(at: Self.directory, permissions: .ownerOnlyDirectory)
        try? memory.writeAtomically(Data(text.utf8), to: memoryURL, permissions: .ownerOnlyFile)
    }
}

@Suite("CollisionMemoryStoreTests: persistence") struct CollisionMemoryStorePersistenceTests {
    /// Written with a 2 s debounce, 0600 in a 0700 folder, schema version 1, never before `load`.
    @Test func writesTwoSecondsAfterTheFirstChangeWithOwnerOnlyPermissions() async {
        let harness = SettingsStoreHarness()
        let memory = harness.store.collisionMemory
        memory.apply([signal("as")])
        #expect(memory.entryCount == 0, "a signal before load is dropped")
        memory.load(vocabulary: vocabulary)
        memory.apply([signal("as"), signal("as", .afterNeutral)])
        await harness.advance(by: .milliseconds(1_900))
        #expect(harness.memoryNode == nil)
        await harness.advance(by: .milliseconds(200))
        #expect(harness.memoryNode?.permissions == .ownerOnlyFile)
        #expect(harness.memory.nodes[SettingsStoreHarness.directory.path]?.permissions == .ownerOnlyDirectory)
        let file = harness.memoryFile()
        #expect(file?["schemaVersion"]?.intValue == 1 && file?["writtenBy"]?.stringValue == "0.1.0")
        #expect(count(file?["entries"]) == 3)
    }

    /// Load keeps only words of the bundled list; the next launch reads the counters back.
    @Test func loadValidatesAgainstTheBundledListAndRoundTrips() async {
        let first = SettingsStoreHarness()
        first.store.collisionMemory.load(vocabulary: vocabulary)
        first.store.collisionMemory.apply([signal("as"), signal("as"), signal("car", .afterEnglish, .english)])
        first.store.collisionMemory.flush()
        let second = SettingsStoreHarness(reusing: first)
        second.store.collisionMemory.load(vocabulary: ["as"])
        #expect(Set(second.store.collisionMemory.memory.entries.keys.map(\.word)) == ["as"])
        #expect(
            second.store.collisionMemory.votes == [
                CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .vietnamese)
            ])
    }

    /// Bad entries are dropped one by one; a file that is not JSON is renamed aside (never deleted) and the memory
    /// starts empty.
    @Test func badEntriesAreDroppedAndACorruptFileIsRenamedAside() {
        let harness = SettingsStoreHarness()
        harness.seedMemory(
            #"{"schemaVersion":1,"writtenBy":"x","entries":["#
                + #"{"word":"as","context":"afterVietnamese","correctionsEnglish":0,"correctionsVietnamese":2,"#
                + #""acceptedEnglish":0,"acceptedVietnamese":0,"classesEnglish":0,"classesVietnamese":0,"#
                + #""decayDay":20770,"lastDay":20770},"#
                + #"{"word":"as","context":"nowhere","correctionsEnglish":0,"correctionsVietnamese":2,"#
                + #""acceptedEnglish":0,"acceptedVietnamese":0,"classesEnglish":0,"classesVietnamese":0,"#
                + #""decayDay":20770,"lastDay":20770},"#
                + #"{"word":"car","context":"any","correctionsEnglish":-1,"correctionsVietnamese":0,"#
                + #""acceptedEnglish":0,"acceptedVietnamese":0,"classesEnglish":0,"classesVietnamese":0,"#
                + #""decayDay":20770,"lastDay":20770}]}"#)
        harness.store.collisionMemory.load(vocabulary: vocabulary)
        #expect(harness.store.collisionMemory.entryCount == 1)

        let corrupt = SettingsStoreHarness()
        corrupt.seedMemory("not json")
        corrupt.store.collisionMemory.load(vocabulary: vocabulary)
        #expect(corrupt.store.collisionMemory.entryCount == 0)
        #expect(corrupt.memoryNode == nil)
        #expect(corrupt.paths.contains { $0.hasPrefix(CollisionMemoryStore.fileName + ".corrupt-") })
    }

    /// A newer schema's file is used for the entries this build knows and never rewritten (as PLT-R1007).
    @Test func aNewerSchemaIsReadOnly() async {
        let harness = SettingsStoreHarness()
        let text =
            #"{"schemaVersion":2,"writtenBy":"9.0","future":true,"entries":[{"word":"as","context":"any","#
            + #""correctionsEnglish":0,"correctionsVietnamese":1,"acceptedEnglish":0,"acceptedVietnamese":0,"#
            + #""classesEnglish":0,"classesVietnamese":2,"decayDay":20770,"lastDay":20770}]}"#
        harness.seedMemory(text)
        harness.store.collisionMemory.load(vocabulary: vocabulary)
        harness.store.collisionMemory.apply([signal("as")])
        await harness.advance(by: .seconds(3))
        harness.store.collisionMemory.flush()
        #expect(harness.memoryNode?.data == Data(text.utf8))
        #expect(harness.store.collisionMemory.entryCount == 2)
    }

    /// "Xóa tất cả" deletes the file and every entry, acceptance counters included (PRD-R78).
    @Test func clearAllDeletesTheFile() {
        let harness = SettingsStoreHarness()
        let memory = harness.store.collisionMemory
        memory.load(vocabulary: vocabulary)
        memory.apply([signal("as"), signal("cos", .sentenceStart, strong: false)])
        memory.flush()
        #expect(harness.memoryNode != nil)
        memory.clearAll()
        #expect(harness.memoryNode == nil)
        #expect(memory.entryCount == 0)
    }

    /// The observer sees the votes when they change, not on every counter update.
    @Test func votesArePublishedOnlyWhenTheyChange() {
        let harness = SettingsStoreHarness()
        let memory = harness.store.collisionMemory
        let recorder = VoteRecorder()
        memory.setObserver { recorder.record($0) }
        memory.load(vocabulary: vocabulary)
        memory.apply([signal("as")])
        memory.apply([signal("as", strong: false)])
        memory.apply([signal("as")])
        memory.forget(word: "as", context: .afterVietnamese)
        #expect(
            recorder.all == [
                [], [CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .vietnamese)], [],
            ])
    }
}

@Suite("CollisionMemoryStoreTests: settings transfer") struct CollisionMemoryTransferTests {
    /// PRD-R72: the export carries a `collisionMemory` section; the import merges by adding counters.
    @Test func exportCarriesTheMemoryAndImportAddsCounters() async throws {
        let source = SettingsStoreHarness()
        _ = await source.store.load()
        source.store.collisionMemory.load(vocabulary: vocabulary)
        source.store.collisionMemory.apply([signal("as")])
        let data = try await source.store.export(ExportOptions(), now: Date(timeIntervalSince1970: 1_800_000_000))
        let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        #expect(count(root?["collisionMemory"]) == 2)

        let target = SettingsStoreHarness()
        _ = await target.store.load()
        target.store.collisionMemory.load(vocabulary: vocabulary)
        target.store.collisionMemory.apply([signal("as")])
        let preview = try await target.store.previewImport(data)
        #expect(preview.collisionMemory == CollisionMemoryImportPreview(importable: 2, skipped: 0, isAvailable: true))
        try await target.store.applyImport(preview, choices: ImportChoices())
        let key = CollisionMemoryKey(word: "as", context: .afterVietnamese)
        #expect(target.store.collisionMemory.memory.entries[key]?.corrections.vietnamese == 2)
        #expect(target.store.collisionMemory.votes.contains { $0.word == "as" && $0.choice == .vietnamese })

        let skipped = SettingsStoreHarness()
        _ = await skipped.store.load()
        skipped.store.collisionMemory.load(vocabulary: vocabulary)
        try await skipped.store.applyImport(preview, choices: ImportChoices(applyCollisionMemory: false))
        #expect(skipped.store.collisionMemory.entryCount == 0)
    }

    /// The export option leaves the section out, and the preview of such a file has no learned words.
    @Test func theSectionCanBeLeftOut() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        harness.store.collisionMemory.load(vocabulary: vocabulary)
        let data = try await harness.store.export(
            ExportOptions(includeCollisionMemory: false), now: Date(timeIntervalSince1970: 1_800_000_000))
        let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        #expect(root?["collisionMemory"] == nil)
        #expect(try await harness.store.previewImport(data).collisionMemory == nil)
    }

    /// PRD-R72, PLT-R914: the preview checks the entries against this build's bundled list exactly as the merge does,
    /// so its count is what will be imported; entries with a word the list does not have, a bad shape or a repeated
    /// key are counted as skipped and left out of what the import applies.
    @Test func thePreviewCountsOnlyWhatTheMergeKeepsAndHowManyAreSkipped() async throws {
        let source = SettingsStoreHarness()
        _ = await source.store.load()
        source.store.collisionMemory.load(vocabulary: ["as", "car", "cos", "tee"])
        source.store.collisionMemory.apply([signal("as"), signal("tee")])
        let data = try Self.appendingEntries(
            to: try await source.store.export(ExportOptions(), now: Date(timeIntervalSince1970: 1_800_000_000)),
            [
                ["word": "AS", "context": "any"],  // not lowercased raw keys: a bad shape
                [
                    "word": "as", "context": "afterVietnamese", "correctionsEnglish": 1, "correctionsVietnamese": 0,
                    "acceptedEnglish": 0, "acceptedVietnamese": 0, "classesEnglish": 0, "classesVietnamese": 0,
                    "decayDay": 20_000, "lastDay": 20_000,
                ],  // a repeated key: the first one wins
            ])

        let target = SettingsStoreHarness()
        _ = await target.store.load()
        target.store.collisionMemory.load(vocabulary: vocabulary)
        let preview = try await target.store.previewImport(data)
        #expect(preview.collisionMemory == CollisionMemoryImportPreview(importable: 2, skipped: 4, isAvailable: true))
        #expect(count(preview.content.objectValue?["collisionMemory"]) == 2, "only the importable entries")
        try await target.store.applyImport(preview, choices: ImportChoices())
        #expect(target.store.collisionMemory.entryCount == 2)
        #expect(!target.store.collisionMemory.memory.entries.keys.contains { $0.word == "tee" })
    }

    /// PLT-R914: while the memory is not loaded (the bundled lists failed to load) nothing can be validated or
    /// written, so the preview says the learned words are unavailable and the import leaves them out entirely; nothing
    /// is kept to be merged later.
    @Test func whileTheMemoryIsNotLoadedTheLearnedWordsAreNotImported() async throws {
        let source = SettingsStoreHarness()
        _ = await source.store.load()
        source.store.collisionMemory.load(vocabulary: vocabulary)
        source.store.collisionMemory.apply([signal("as")])
        let data = try await source.store.export(ExportOptions(), now: Date(timeIntervalSince1970: 1_800_000_000))

        let target = SettingsStoreHarness()
        _ = await target.store.load()
        #expect(!target.store.collisionMemory.isLoaded)
        let preview = try await target.store.previewImport(data)
        #expect(preview.collisionMemory == CollisionMemoryImportPreview(importable: 0, skipped: 0, isAvailable: false))
        #expect(preview.content.objectValue?["collisionMemory"] == nil)
        #expect(preview.content.objectValue?["settings"] != nil, "the rest of the file is still offered")
        try await target.store.applyImport(preview, choices: ImportChoices())
        target.store.collisionMemory.load(vocabulary: vocabulary)
        #expect(target.store.collisionMemory.entryCount == 0, "nothing was kept for a later load")
    }

    /// The export with `extra` appended to its `collisionMemory` section.
    private static func appendingEntries(to data: Data, _ extra: [[String: Any]]) throws -> Data {
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(root["collisionMemory"] as? [Any])
        root["collisionMemory"] = entries + extra
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// The memory was never loaded (the bundled lists failed): the export leaves the section out rather than send an
    /// empty list that would read as "no learned words", and the file stays as it is.
    @Test func anExportWhileTheMemoryIsNotLoadedLeavesTheSectionOut() async throws {
        let first = SettingsStoreHarness()
        first.store.collisionMemory.load(vocabulary: vocabulary)
        first.store.collisionMemory.apply([signal("as")])
        first.store.collisionMemory.flush()
        let harness = SettingsStoreHarness(reusing: first)
        _ = await harness.store.load()
        let data = try await harness.store.export(ExportOptions(), now: Date(timeIntervalSince1970: 1_800_000_000))
        let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
        #expect(root?["collisionMemory"] == nil)
        #expect(count(harness.memoryFile()?["entries"]) == 2)
    }

    /// The sheet's "Xóa tất cả" acts on the memory it lists: while the memory is not loaded the sheet is empty and
    /// the button leaves the file alone. The pane and full resets, explicit requests, still delete it.
    @Test func theSheetsClearAllLeavesAnUnloadedMemoryAlone() async {
        let first = SettingsStoreHarness()
        first.store.collisionMemory.load(vocabulary: vocabulary)
        first.store.collisionMemory.apply([signal("as")])
        first.store.collisionMemory.flush()
        let harness = SettingsStoreHarness(reusing: first)
        _ = await harness.store.load()
        await harness.store.clearCollisionMemory()
        #expect(harness.memoryNode != nil)
        await harness.store.reset(.typing)
        #expect(harness.memoryNode == nil)
    }

    /// PLT-R912: an imported entry dated in the future (a Mac with a wrong date, or a crafted export) is dated today
    /// before it is merged, so it neither ages the local counters to that day nor freezes their decay.
    @Test(arguments: [false, true])
    func importedDaysInTheFutureAreDatedToday(importedBeforeLoad: Bool) {
        let harness = SettingsStoreHarness()
        let memory = harness.store.collisionMemory
        let today = CollisionMemory.day(of: harness.wallClock.now())
        let key = CollisionMemoryKey(word: "car", context: .afterEnglish)
        var future = CollisionMemoryEntry(day: today + 1_000)
        future.corrections.vietnamese = 1
        let imported = CollisionMemory(entries: [key: future])
        if importedBeforeLoad {
            memory.merge(imported)
            memory.load(vocabulary: vocabulary)
            #expect(memory.memory.entries[key]?.decayDay == today)
            #expect(memory.memory.entries[key]?.lastDay == today)
            return
        }
        memory.load(vocabulary: vocabulary)
        memory.apply([signal("car", .afterEnglish, .english), signal("car", .afterEnglish, .english)])
        memory.merge(imported)
        let entry = memory.memory.entries[key]
        #expect(entry?.corrections.english == 2)
        #expect(entry?.corrections.vietnamese == 1)
        #expect(entry?.decayDay == today && entry?.lastDay == today)
    }

    /// PRD-R26: the Typing pane reset clears the learned collision choices with the other Typing lists; D28 and D29
    /// are Typing settings and go back to unset.
    @Test func theTypingResetClearsTheMemory() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.updateSettings {
            $0.learnCollisionChoices = .set(false)
            $0.lookaheadRevision = .set(false)
        }
        harness.store.collisionMemory.load(vocabulary: vocabulary)
        harness.store.collisionMemory.apply([signal("as")])
        harness.store.collisionMemory.flush()
        await harness.store.reset(.typing)
        #expect(harness.store.collisionMemory.entryCount == 0)
        #expect(harness.memoryNode == nil)
        let user = await harness.store.state.user
        #expect(user.learnCollisionChoices == .unset && user.lookaheadRevision == .unset)
    }

    /// D28 and D29 default on (decision of the product owner, 15/11/2026).
    @Test func d28AndD29DefaultOn() {
        #expect(DefaultSettings.v1.learnCollisionChoices && DefaultSettings.v1.lookaheadRevision)
        var user = UserSettings()
        user.learnCollisionChoices = .set(false)
        #expect(!user.resolved().learnCollisionChoices && user.resolved().lookaheadRevision)
    }
}
