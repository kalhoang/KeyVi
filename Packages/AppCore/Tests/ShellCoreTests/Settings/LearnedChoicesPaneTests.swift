// SPDX-License-Identifier: GPL-3.0-or-later
//
// The learned-words sheet of the Typing pane (PRD-R78, PRD-R79; decision of the product owner, 15/11/2026: collision
// choices are learned per user across all apps, from corrections and silent acceptance). One row per memory entry
// that votes for a side, rendered from the bundled word as word, arrow, result and context in words; remove per row
// and "Xóa tất cả" go to the store's collision memory (PLT-R914); D28 off keeps the memory; the Typing pane reset
// clears it (PRD-R26). Workstream W11-C.

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

/// The Vietnamese readings the fixture rows use; the real ones come from the engine (`CollisionWordReading`).
private let readings = ["as": "á", "car": "cả", "cos": "có", "gif": "gì"]
private func reading(_ word: String) -> String { readings[word] ?? word }

/// A store snapshot as `CollisionMemoryStore.learnedChoices` could hand it over, deliberately out of order and with
/// a conflict, which the sheet never lists.
private let fixture: [CollisionMemoryVote] = [
    CollisionMemoryVote(word: "gif", context: .afterNeutral, choice: .vietnamese),
    CollisionMemoryVote(word: "car", context: .sentenceStart, choice: .english),
    CollisionMemoryVote(word: "as", context: .afterEnglish, choice: .english),
    CollisionMemoryVote(word: "cos", context: .afterEnglish, choice: .conflict),
    CollisionMemoryVote(word: "as", context: nil, choice: .vietnamese),
    CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .vietnamese),
]

private func strong(
    _ word: String, _ context: CollisionMemoryContext, _ side: CollisionMemorySide
) -> CollisionMemorySignal {
    CollisionMemorySignal(word: word, context: context, side: side, strength: .strong)
}

@Suite struct LearnedChoicesPaneTests {
    // MARK: Rows (PRD-R78)

    @Test func rowsComeFromTheVotingEntriesByWordThenContext() {
        let sheet = LearnedChoicesSheetState(votes: fixture, reading: reading)
        // The memory's key order: word, the any-context entry, then the classes in declaration order.
        #expect(sheet.rows.map(\.word) == ["as", "as", "as", "car", "gif"])
        #expect(sheet.rows.map(\.context) == [nil, .afterVietnamese, .afterEnglish, .sentenceStart, .afterNeutral])
        #expect(sheet.rows.map(\.side) == [.vietnamese, .vietnamese, .english, .english, .vietnamese])
        #expect(!sheet.rows.contains { $0.word == "cos" }, "a conflict is not a choice, the rules decide")
        #expect(!sheet.isEmpty)
        #expect(Set(sheet.rows.map(\.id)).count == sheet.rows.count, "one row per entry")
    }

    @Test func eachRowShowsWhatTheWordBecomesFromTheBundledWord() {
        let rows = LearnedChoicesSheetState(votes: fixture, reading: reading).rows
        // Vietnamese: the word's Telex reading; English: the keys themselves (`car -> car`).
        #expect(rows.map(\.result) == ["á", "á", "as", "car", "gì"])
    }

    @Test func theRealReadingIsTheEnginesTelexDisplayOfTheBundledWord() {
        let rows = LearnedChoicesSheetState(votes: [
            CollisionMemoryVote(word: "as", context: .afterVietnamese, choice: .vietnamese),
            CollisionMemoryVote(word: "car", context: nil, choice: .vietnamese),
            CollisionMemoryVote(word: "cos", context: .sentenceStart, choice: .vietnamese),
        ]).rows
        #expect(rows.map(\.result) == ["á", "cả", "có"])
    }

    @Test func contextIsSaidInWordsInBothLanguages() throws {
        let l = try Localizers()
        let rows = LearnedChoicesSheetState(votes: fixture, reading: reading).rows
        #expect(
            rows.map { $0.contextText(l.vi) } == [
                "mọi ngữ cảnh", "sau từ tiếng Việt", "sau từ tiếng Anh", "đầu câu", "sau từ không rõ ngôn ngữ",
            ])
        #expect(
            rows.map { $0.contextText(l.en) } == [
                "any context", "after a Vietnamese word", "after an English word", "sentence start",
                "after a word of unclear language",
            ])
    }

    @Test func voiceOverReadsTheWholeChoiceAndTheRemoveButtonNamesItsRow_PRDR66() throws {
        let l = try Localizers()
        let rows = LearnedChoicesSheetState(votes: fixture, reading: reading).rows
        #expect(rows[1].accessibilityText(l.vi) == "as thành á, sau từ tiếng Việt")
        #expect(rows[1].accessibilityText(l.en) == "as becomes á, after a Vietnamese word")
        #expect(rows[3].accessibilityText(l.vi) == "car giữ nguyên tiếng Anh, đầu câu")
        #expect(rows[3].accessibilityText(l.en) == "car stays English, sentence start")
        // Two rows of one word differ by their context, so the button says which one it removes.
        #expect(rows[0].removeLabel(l.vi) == "Xóa \"as\", mọi ngữ cảnh")
        #expect(rows[2].removeLabel(l.en) == "Remove \"as\", after an English word")
        for localizer in [l.vi, l.en] {
            for control in [
                SettingsControl.learnCollisionChoices, .learnedChoicesShow, .learnedChoiceRemove,
                .learnedChoicesRemoveAll, .learnedChoicesDone, .learnedClearConfirm, .learnedClearCancel,
                .lookaheadRevision,
            ] {
                #expect(!localizer.accessibilityLabel(control).hasPrefix("settings."), "\(control) label")
                #expect(!localizer.accessibilityHint(control).hasPrefix("settings."), "\(control) hint")
            }
        }
    }

    // MARK: Empty state

    @Test func emptyStateSaysHowWordsAreLearnedWithTheAppNameAsArgument() throws {
        let l = try Localizers()
        let empty = LearnedChoicesSheetState(votes: [], reading: reading)
        #expect(empty.isEmpty && empty.rows.isEmpty)
        let onlyConflicts = LearnedChoicesSheetState(
            votes: [CollisionMemoryVote(word: "as", context: nil, choice: .conflict)], reading: reading)
        #expect(onlyConflicts.isEmpty)
        #expect(
            LearnedChoicesSheetState.emptyText(appName: "{{AppName}}", l.vi)
                == "Chưa có từ nào. {{AppName}} học khi bạn sửa một từ bằng phím Escape.")
        #expect(
            LearnedChoicesSheetState.emptyText(appName: "{{AppName}}", l.en)
                == "No words yet. {{AppName}} learns when you correct a word with the Escape key.")
    }

    // MARK: Remove and clear (PRD-R78, PLT-R914)

    @Test func removeAndClearAreEditsOfTheMemoryNotOfSettingsJSON() {
        let sheet = LearnedChoicesSheetState(votes: fixture, reading: reading)
        let row = sheet.rows[1]
        #expect(row.forgetEdit == .forgetLearnedChoice(CollisionMemoryKey(word: "as", context: .afterVietnamese)))
        let removed = sheet.removing(row)
        #expect(removed.rows.count == sheet.rows.count - 1 && !removed.rows.contains(row))
        #expect(sheet.rows.contains(row), "the sheet state is a value: the original keeps its rows")
        #expect(sheet.cleared.isEmpty)
        // The memory is in collision-memory.json: neither edit writes a settings.json key.
        for edit in [row.forgetEdit, SettingsEdit.clearLearnedChoices] {
            var settings = UserSettings()
            edit.apply(to: &settings)
            #expect(settings == UserSettings(), "\(edit)")
            #expect(edit.item == .learnCollisionChoices)
            #expect(edit.editsLearnedChoices)
        }
        #expect(!SettingsEdit.learnCollisionChoices(false).editsLearnedChoices)
    }

    @Test func clearAllAsksFirst() {
        let sheet = LearnedChoicesSheetState(votes: fixture, reading: reading)
        #expect(!sheet.confirmsClearAll)
        let asking = sheet.confirmingClearAll(true)
        #expect(asking.confirmsClearAll && asking.rows == sheet.rows)
        #expect(!asking.cleared.confirmsClearAll && asking.cleared.isEmpty)
        #expect(!asking.confirmingClearAll(false).confirmsClearAll)
        // New votes from the store keep the open confirmation.
        #expect(asking.replacingVotes([], reading: reading).confirmsClearAll)
    }

    @Test func commandsRemoveOneEntryAndClearEveryEntryOfTheStore() async throws {
        let (harness, commands) = await Self.loadedWithMemory()
        let memory = harness.store.collisionMemory
        let before = memory.entryCount
        var sheet = LearnedChoicesSheetState(votes: await commands.learnedChoices())
        #expect(sheet.rows.map(\.word) == ["as", "car"])
        #expect(sheet.rows.map(\.result) == ["á", "car"])

        _ = await commands.apply(sheet.rows[0].forgetEdit)
        sheet = LearnedChoicesSheetState(votes: await commands.learnedChoices())
        #expect(sheet.rows.map(\.word) == ["car"])
        #expect(memory.entryCount == before - 1, "only that entry; the word's any-context entry stays")

        // "Xóa tất cả" also deletes the acceptance-only entries the sheet never lists, and the file.
        await harness.advance(by: .seconds(2))
        #expect(harness.memory.nodes[Self.memoryPath] != nil)
        let state = await commands.apply(.clearLearnedChoices)
        #expect(state.user == (await commands.state()).user)
        #expect(await commands.learnedChoices().isEmpty)
        #expect(memory.entryCount == 0)
        #expect(harness.memory.nodes[Self.memoryPath] == nil)
    }

    @Test func turningLearningOffKeepsTheLearnedWords_PRDR78() async {
        let (_, commands) = await Self.loadedWithMemory()
        let state = await commands.apply(.learnCollisionChoices(false))
        #expect(state.effective.learnCollisionChoices == false)
        #expect(state.user.explicitlySetKeys == ["learnCollisionChoices"])
        #expect(await commands.learnedChoices().count == 2, "the list stays until Xóa tất cả")
    }

    // MARK: Typing pane reset (PRD-R26)

    @Test func theTypingResetSaysItClearsTheLearnedWordsAndDoes() async throws {
        let l = try Localizers()
        let request = ResetRequest(target: .pane(.typing))
        #expect(request.body == .resetBodyTyping)
        #expect(l.vi.string(request.body).contains("các từ đã học"))
        #expect(l.en.string(request.body).contains("learned words"))
        let (harness, commands) = await Self.loadedWithMemory()
        _ = await commands.apply(.lookaheadRevision(false))
        let state = await commands.perform(request.plan)
        #expect(state.effective.lookaheadRevision, "D29 is back to its default")
        #expect(harness.store.collisionMemory.entryCount == 0)
        #expect(await commands.learnedChoices().isEmpty)
    }

    // MARK: Copy (PRD-R25, PRD-R62, PRD-R79)

    @Test func everyNewStringExistsInBothLanguages() throws {
        let l = try Localizers()
        let keys: [SettingsText] = [
            .learnCollisionTitle, .learnCollisionExplanation, .learnedChoicesShow, .learnedChoicesTitle,
            .learnedChoicesIntro, .learnedChoicesEmpty, .learnedChoicesRemoveAll, .learnedChoicesDone,
            .learnedContextSentenceStart, .learnedContextAfterVietnamese, .learnedContextAfterEnglish,
            .learnedContextAfterNeutral, .learnedContextAny, .learnedRowVietnamese, .learnedRowEnglish,
            .learnedClearTitle, .learnedClearBody, .learnedClearConfirm, .learnedClearCancel, .lookaheadRevisionTitle,
            .lookaheadRevisionExplanation, .exportIncludeLearnedChoices, .importLearnedChoices,
            .importApplyLearnedChoices,
        ]
        for key in keys {
            let vi = l.vi.string(key)
            let en = l.en.string(key)
            #expect(vi != key.rawValue && en != key.rawValue, "\(key) is missing")
            #expect(vi != en || key == .learnedContextAny, "\(key) is not translated")
            #expect(!vi.contains("tệp"), "\(key): the copy says file")
        }
        // PRD-R79: the drafts of the design, app name as an argument.
        #expect(l.vi.string(SettingsText.learnedChoicesShow) == "Xem từ đã học...")
        #expect(l.vi.string(SettingsText.learnedChoicesRemoveAll) == "Xóa tất cả...")
        #expect(l.en.string(SettingsText.learnedChoicesShow) == "Show learned words...")
        #expect(l.vi.format(SettingsText.learnedClearBody, "{{AppName}}").hasPrefix("{{AppName}} "))
    }

    @Test func bothItemsHaveATitleAndAOneLineExplanation_PRDR25() throws {
        let l = try Localizers()
        for item in [SettingItem.learnCollisionChoices, .lookaheadRevision] {
            for localizer in [l.vi, l.en] {
                let title = localizer.string(item.title)
                let explanation = localizer.format(item.explanation, "{{AppName}}")
                #expect(!title.hasPrefix("settings.") && !explanation.hasPrefix("settings."), "\(item)")
                #expect(!explanation.contains("\n") && explanation != title, "\(item): one line")
            }
        }
        #expect(
            l.vi.format(SettingItem.learnCollisionChoices.explanation, "{{AppName}}")
                == "Khi bạn sửa một từ vừa là tiếng Anh vừa là tiếng Việt (as/á, car/cả), {{AppName}} ghi nhớ lựa "
                + "chọn đó cho lần sau. Chỉ lưu trên máy này.")
        #expect(
            l.vi.string(SettingItem.lookaheadRevision.explanation)
                == "Ví dụ: gõ tricky as hell thì á đổi lại thành as khi bạn gõ hell. Tắt trong Terminal và trình "
                + "soạn mã theo quy tắc ứng dụng.")
        #expect(l.en.format(SettingItem.learnCollisionChoices.explanation, "{{AppName}}").contains("{{AppName}}"))
    }

    // MARK: Import (PRD-R72)

    @Test func theImportSummaryCountsTheLearnedWordsAndOffersToSkipThem() async throws {
        let l = try Localizers()
        let (_, commands) = await Self.loadedWithMemory()
        let now = Date(timeIntervalSince1970: 1_794_700_000)
        let data = try await commands.export(ExportOptions(includeMacros: false, includeAppModes: false), now: now)
        var summary = ImportSummary(preview: try await commands.previewImport(data))
        // Six entries: a class entry and an any-context entry for each of as, car and cos.
        #expect(summary.hasLearnedChoices && summary.choices.applyCollisionMemory)
        #expect(summary.lines(l.vi).contains("Từ đã học: 6 mục"))
        #expect(summary.lines(l.en).contains("Learned word entries: 6"))
        summary.choices.applySettings = false
        summary.choices.applyRuleOverrides = false
        #expect(!summary.isEmptySelection, "the learned words alone can be imported")
        summary.choices.applyCollisionMemory = false
        #expect(summary.isEmptySelection)

        let without = try await commands.export(ExportOptions(includeCollisionMemory: false), now: now)
        let none = ImportSummary(preview: try await commands.previewImport(without))
        #expect(!none.hasLearnedChoices && !none.lines(l.vi).contains { $0.hasPrefix("Từ đã học") })
    }

    // MARK: Helpers

    static var memoryPath: String {
        SettingsStoreHarness.directory.appendingPathComponent(CollisionMemoryStore.fileName).path
    }

    /// A loaded store whose memory votes `as` -> á after a Vietnamese word and `car` -> car at a sentence start,
    /// and holds an acceptance-only entry for `cos` that votes for nothing.
    static func loadedWithMemory() async -> (SettingsStoreHarness, SettingsCommands) {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let memory = harness.store.collisionMemory
        memory.load(vocabulary: ["as", "car", "cos"])
        memory.apply([
            strong("as", .afterVietnamese, .vietnamese), strong("as", .afterVietnamese, .vietnamese),
            strong("car", .sentenceStart, .english), strong("car", .sentenceStart, .english),
            CollisionMemorySignal(word: "cos", context: .afterVietnamese, side: .vietnamese, strength: .weak),
        ])
        return (harness, SettingsCommands(store: harness.store))
    }
}
