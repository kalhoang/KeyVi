// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typing pane lists with per-app learned words (ENG-R862, 03-product.md section 7): each learned entry shows the app
// it was learned in and can be removed or made global; words typed in Settings stay global. Bundle IDs are test
// fixtures (PLT-R501). Workstream W5-B.

import AppModel
import Diagnostics
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

private let editor = BundleKey(rawValue: "com.example.editor")!
private let chat = BundleKey(rawValue: "com.example.chat")!

@Suite struct LearnedWordsPaneTests {
    private var settings: UserSettings {
        var user = UserSettings()
        user.keepAsTyped = ["tar", "text"]
        user.keepVietnamese = ["mas"]
        user.learn("tar", in: .keepAsTyped, app: editor)
        user.learnedWords.insert(LearnedWord(list: .keepAsTyped, raw: "tar", app: chat))
        user.learn("cos", in: .keepAsTyped, app: chat)
        user.learn("ddi", in: .keepVietnamese, app: editor)
        return user
    }

    @Test func rowsListGlobalAndLearnedEntriesByWord() {
        let rows = UserWordList.keepAsTyped.rows(in: settings)
        #expect(rows.map(\.word) == ["cos", "tar", "tar", "text"])
        #expect(rows.map(\.learned?.app) == [chat, nil, chat, nil])
        #expect(Set(rows.map(\.id)).count == rows.count, "the same word in two places has two rows")
        let vietnamese = UserWordList.keepVietnamese.rows(in: settings)
        #expect(vietnamese.map(\.word) == ["ddi", "mas"])
        #expect(vietnamese.first?.learned == LearnedWord(list: .keepVietnamese, raw: "ddi", app: editor))
        #expect(UserWordList.keepAsTyped.restoreList == .keepAsTyped)
        #expect(UserWordList.keepVietnamese.restoreList == .keepVietnamese)
    }

    @Test func removeAndMakeGlobalAreEditsOfTheirList_ENGR862() {
        let cos = LearnedWord(list: .keepAsTyped, raw: "cos", app: chat)
        var user = settings
        SettingsEdit.makeLearnedWordGlobal(cos).apply(to: &user)
        #expect(user.keepAsTyped.contains("cos"))
        #expect(!user.learnedWords.contains(cos))
        let ddi = LearnedWord(list: .keepVietnamese, raw: "ddi", app: editor)
        SettingsEdit.forgetLearnedWord(ddi).apply(to: &user)
        #expect(!user.learnedWords.contains(ddi) && !user.keepVietnamese.contains("ddi"))
        #expect(SettingsEdit.makeLearnedWordGlobal(cos).item == .keepAsTyped)
        #expect(SettingsEdit.forgetLearnedWord(ddi).item == .keepVietnamese)
    }

    /// A word typed in Settings is global; the same word learned for that list in an app is then redundant.
    @Test func typingAWordInSettingsKeepsItGlobal() {
        var user = UserSettings()
        user.learn("cos", in: .keepAsTyped, app: chat)
        user.learn("cos", in: .keepVietnamese, app: editor)
        guard case .added(let entries) = UserWordList.adding("Cos", to: user.keepAsTyped) else {
            Issue.record("expected the word to be added")
            return
        }
        UserWordList.keepAsTyped.edit(entries).apply(to: &user)
        #expect(user.keepAsTyped == ["cos"])
        #expect(user.learnedWords == [LearnedWord(list: .keepVietnamese, raw: "cos", app: editor)])
    }

    @Test func theAppNameAndTheButtonsAreLocalised() throws {
        let l = try Localizers()
        #expect(l.vi.format(SettingsText.listLearnedIn, "TextEdit") == "Chỉ trong TextEdit")
        #expect(l.en.format(SettingsText.listLearnedIn, "TextEdit") == "Only in TextEdit")
        #expect(l.vi.format(SettingsText.listMakeGlobal, "cos") == "Dùng \"cos\" trong mọi ứng dụng")
        #expect(l.en.format(SettingsText.listMakeGlobal, "cos") == "Use \"cos\" in all apps")
        for localizer in [l.vi, l.en] {
            #expect(!localizer.string(SettingsText.listLearnedNote).hasPrefix("settings."))
            #expect(!localizer.accessibilityLabel(SettingsControl.wordMakeGlobal).hasPrefix("settings."))
            #expect(!localizer.accessibilityHint(SettingsControl.wordMakeGlobal).hasPrefix("settings."))
        }
    }

    /// ADR 0314, PLT-R901: the report names the learned list, never its words or the apps they were learned in.
    @Test func theReportNamesTheLearnedListButNoWordOrApp_PLTR901() throws {
        var user = UserSettings()
        let app = try #require(BundleKey(rawValue: Canary.otherBundle))
        user.learn(Canary.userList, in: .keepAsTyped, app: app)
        var report = ReportFixtures.report()
        report.settings = ReportSections.settings(SettingsState(user: user))
        #expect(report.settings.explicitlySetKeys == ["learnedWords"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let outputs = [
            String(decoding: try encoder.encode(report), as: UTF8.self), DiagnosticsRenderer.issueBlock(report),
            DiagnosticsRenderer.plainText(report, language: .vietnamese),
            DiagnosticsRenderer.plainText(report, language: .english),
        ]
        for output in outputs {
            #expect(!output.contains("zqxkanary"), "a learned word or its app leaked into the report")
            #expect(output.contains("learnedWords"), "the list name is reported")
        }
    }
}
