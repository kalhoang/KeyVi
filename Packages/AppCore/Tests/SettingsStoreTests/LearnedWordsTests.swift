// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-app learning (ENG-R861, ENG-R862, decision of 13/11/2026, ADR 0320): learned words apply only in their app,
// words typed in Settings stay global, the host gives the engine the lists of the focused app (ENG-R851), and
// settings.json, export and import carry the app. Bundle IDs below are test fixtures (PLT-R501). Workstream W5-B.

import AppModel
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

private let editor = BundleKey(rawValue: "com.example.editor")!
private let chat = BundleKey(rawValue: "com.example.chat")!

private func object(_ text: String) throws -> [String: JSONValue] {
    try JSONSupport.parseObject(Data(text.utf8))
}

@Suite struct LearnedWordsModelTests {
    @Test func aWordLearnedInOneAppAppliesOnlyThere_ENGR862() {
        var user = UserSettings()
        user.keepAsTyped = ["text"]
        user.learn("TAR", in: .keepAsTyped, app: editor)
        #expect(user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)])
        #expect(user.keepAsTyped == ["text"], "learning never touches the global entries")
        #expect(user.wordLists(for: editor) == UserWordLists(keepAsTyped: ["text", "tar"], keepVietnamese: []))
        #expect(user.wordLists(for: chat) == UserWordLists(keepAsTyped: ["text"], keepVietnamese: []))
        #expect(user.wordLists(for: nil) == user.globalWordLists)
    }

    /// The app's own choice is more specific than a global entry of the other list.
    @Test func aLearnedWordWinsOverTheOtherGlobalListInItsApp() {
        var user = UserSettings()
        user.keepVietnamese = ["mas"]
        user.learn("mas", in: .keepAsTyped, app: editor)
        #expect(user.wordLists(for: editor) == UserWordLists(keepAsTyped: ["mas"], keepVietnamese: []))
        #expect(user.wordLists(for: chat) == UserWordLists(keepAsTyped: [], keepVietnamese: ["mas"]))
    }

    /// ENG-R860 "newest choice wins", per app.
    @Test func learningTheOtherListReplacesTheEntryInThatAppOnly() {
        var user = UserSettings()
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("tar", in: .keepAsTyped, app: chat)
        user.learn("tar", in: .keepVietnamese, app: editor)
        #expect(
            user.learnedWords == [
                LearnedWord(list: .keepVietnamese, raw: "tar", app: editor),
                LearnedWord(list: .keepAsTyped, raw: "tar", app: chat),
            ])
    }

    @Test func nothingIsLearnedWhenAGlobalEntryAlreadyApplies() {
        var user = UserSettings()
        user.keepAsTyped = ["tar"]
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("", in: .keepAsTyped, app: editor)
        #expect(user.learnedWords.isEmpty)
    }

    @Test func removingALearnedWordKeepsTheOthers() {
        var user = UserSettings()
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("tar", in: .keepAsTyped, app: chat)
        user.forget(LearnedWord(list: .keepAsTyped, raw: "tar", app: editor))
        #expect(user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: chat)])
    }

    /// Settings "use in every app": global in its list, out of the other global list, same-list copies dropped,
    /// other-list words of other apps kept.
    @Test func makingALearnedWordGlobal() {
        var user = UserSettings()
        user.keepVietnamese = ["tar", "mas"]
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("tar", in: .keepAsTyped, app: chat)
        let other = BundleKey(rawValue: "com.example.mail")!
        user.learnedWords.insert(LearnedWord(list: .keepVietnamese, raw: "tar", app: other))
        user.makeGlobal(LearnedWord(list: .keepAsTyped, raw: "tar", app: editor))
        #expect(user.keepAsTyped == ["tar"])
        #expect(user.keepVietnamese == ["mas"])
        #expect(user.learnedWords == [LearnedWord(list: .keepVietnamese, raw: "tar", app: other)])
        // An entry that is not stored changes nothing.
        let before = user
        user.makeGlobal(LearnedWord(list: .keepAsTyped, raw: "zzz", app: editor))
        #expect(user == before)
    }

    @Test func aWordTypedInSettingsMakesTheSameLearnedEntriesRedundant() {
        var user = UserSettings()
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("mas", in: .keepVietnamese, app: editor)
        user.setGlobalWords(["tar"], in: .keepAsTyped)
        #expect(user.keepAsTyped == ["tar"])
        #expect(user.learnedWords == [LearnedWord(list: .keepVietnamese, raw: "mas", app: editor)])
    }

    @Test func explicitlySetKeysNameTheLearnedListButNeverItsContent_ADR0314() {
        var user = UserSettings()
        user.learn("canary", in: .keepAsTyped, app: editor)
        #expect(user.explicitlySetKeys == ["learnedWords"])
        #expect(!user.explicitlySetKeys.joined().contains("canary"))
        #expect(!user.explicitlySetKeys.joined().contains(editor.rawValue))
    }
}

@Suite struct LearnedWordsCodecTests {
    @Test func learnedWordsRoundTripWithTheirApp() throws {
        var user = UserSettings()
        user.keepAsTyped = ["text"]
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learn("mas", in: .keepVietnamese, app: chat)
        let encoded = SettingsCodec.encode(user, over: [:])
        #expect(
            encoded["englishRestoreLists"]?["learnedWords"]
                == .array([
                    .object(["list": .string("keepVietnamese"), "raw": .string("mas"), "app": .string(chat.rawValue)]),
                    .object(["list": .string("keepAsTyped"), "raw": .string("tar"), "app": .string(editor.rawValue)]),
                ]))
        #expect(SettingsCodec.decode(encoded) == user)
    }

    /// Migration (ADR 0320): a settings.json written before per-app learning has no `learnedWords`; its entries
    /// carry no app and stay global. The released v1 fixture loads unchanged.
    @Test func filesFromBeforePerAppLearningKeepTheirEntriesGlobal() throws {
        let user = SettingsCodec.decode(try object(SchemaFixtures.v1.settings))
        #expect(user.keepAsTyped == ["tex"])
        #expect(user.keepVietnamese == ["mas"])
        #expect(user.learnedWords.isEmpty)
        #expect(user.wordLists(for: editor) == user.globalWordLists)
    }

    /// An item without an app is global; unreadable items are skipped, kept out of the payload and listed for the
    /// import summary; unknown keys inside an item survive a rewrite (PLT-R1002).
    @Test func itemsWithoutAnAppAreGlobalAndBadItemsAreSkipped() throws {
        let raw = try object(
            #"""
            {"englishRestoreLists": {"learnedWords": [
              {"list": "keepAsTyped", "raw": "Tar", "app": "com.example.editor", "futureKey": 1},
              {"list": "keepVietnamese", "raw": "mas"},
              {"list": "keepAsTyped", "raw": "cos", "app": null},
              {"list": "keepSomething", "raw": "x", "app": "com.example.editor"},
              {"list": "keepAsTyped", "raw": "", "app": "com.example.editor"},
              {"list": "keepAsTyped", "raw": "y", "app": 7},
              "word"
            ]}}
            """#)
        let user = SettingsCodec.decode(raw)
        #expect(user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)])
        #expect(user.keepVietnamese == ["mas"])
        #expect(user.keepAsTyped == ["cos"])
        #expect(
            SettingsCodec.skippedPaths(in: raw) == [
                "englishRestoreLists.learnedWords[3]", "englishRestoreLists.learnedWords[4]",
                "englishRestoreLists.learnedWords[5]", "englishRestoreLists.learnedWords[6]",
            ])
        let rewritten = SettingsCodec.encode(user, over: raw)
        #expect(
            rewritten["englishRestoreLists"]?["learnedWords"]
                == .array([
                    .object([
                        "list": .string("keepAsTyped"), "raw": .string("tar"), "app": .string(editor.rawValue),
                        "futureKey": .number(1),
                    ])
                ]))
        #expect(rewritten["englishRestoreLists"]?["keepAsTyped"] == .array([.string("cos")]))
    }
}

@Suite struct LearnedWordsStoreTests {
    private func learned(_ harness: SettingsStoreHarness) async {
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.learn("tar", in: .keepAsTyped, app: editor) }
    }

    @Test func learnedWordsAreSavedWithTheirApp() async throws {
        let harness = SettingsStoreHarness()
        await learned(harness)
        await harness.advance(by: .seconds(1))
        let written = try #require(harness.object(.settings))
        #expect(arrayItems(written["englishRestoreLists"]?["learnedWords"]).first?["app"] == .string(editor.rawValue))
        let next = SettingsStoreHarness(reusing: harness)
        #expect(await next.store.load().user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)])
    }

    /// PLT-R1010: export and import carry the app field.
    @Test func exportAndImportCarryTheApp() async throws {
        let source = SettingsStoreHarness()
        await learned(source)
        let data = try await source.store.export(ExportOptions(), now: Date(timeIntervalSince1970: 1_794_528_000))
        let exported = try JSONSupport.parseObject(data)
        let exportedWords = arrayItems(exported["settings"]?["englishRestoreLists"]?["learnedWords"])
        #expect(exportedWords.first?["app"] == .string(editor.rawValue))

        let target = SettingsStoreHarness()
        _ = await target.store.load()
        let preview = try await target.store.previewImport(data)
        #expect(preview.changedSettingKeys.contains("learnedWords"))
        #expect(!preview.skippedFields.contains { $0.contains("learnedWords") })
        try await target.store.applyImport(preview, choices: ImportChoices())
        #expect(
            await target.store.state.user.learnedWords == [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)])
    }

    @Test func resettingTheTypingPaneForgetsLearnedWords_PRDR26() async {
        let harness = SettingsStoreHarness()
        await learned(harness)
        await harness.store.reset(.typing)
        #expect(await harness.store.state.user.learnedWords.isEmpty)
    }
}
