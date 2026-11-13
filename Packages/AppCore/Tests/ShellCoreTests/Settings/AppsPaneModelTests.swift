// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R34 rows, PRD-R35 matrix status (the app row through MatrixDocument.appEntry(for:) and
// MatrixStatusResolver.displayStatus, scoped rows only in the detail view), PRD-R36 and PLT-R540 compatibility
// mode overrides.

import AppModel
import CompatRules
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct CompatibilityModeChoiceTests {
    let bundle = BundleKey(rawValue: "com.example.Chat")!

    @Test func automaticRemovesTheOverride() {
        #expect(CompatibilityModeChoice.automatic.overrideRule(for: bundle, date: "2026-11-13") == nil)
    }

    @Test func choicesWriteUserOverridesScopedToThisApp() throws {
        let slower = try #require(CompatibilityModeChoice.typeSlower.overrideRule(for: bundle, date: "2026-11-13"))
        #expect(slower["id"] == .string("user.compat.com.example.Chat"))
        #expect(slower["match"] == .object(["bundleIds": .array([.string("com.example.Chat")])]))
        #expect(slower["action"]?["strategy"] == .string("backspaceReplace"))
        #expect(slower["action"]?["params"]?["interEventDelayUs"]?.intValue == 5_000)
        #expect(slower["provenance"]?["date"] == .string("2026-11-13"))
        #expect(slower["provenance"]?["source"] == .string("user-suggestion"))
        let select = try #require(CompatibilityModeChoice.selectThenType.overrideRule(for: bundle, date: "d"))
        #expect(select["action"] == .object(["strategy": .string("selectReplace")]))
        let paste = try #require(CompatibilityModeChoice.pasteText.overrideRule(for: bundle, date: "d"))
        #expect(paste["action"] == .object(["strategy": .string("paste")]))
    }

    @Test func overridesDecodeAsRulesOfTheSchema() throws {
        for choice in CompatibilityModeChoice.allCases where choice != .automatic {
            var json = try #require(choice.overrideRule(for: bundle, date: "2026-11-13"))
            #expect(CompatibilityModeChoice(overrideRule: json) == choice)
            json = .object(json.objectValue!.filter { $0.key != "provenance" })  // provenance coding is W1-C's
            let rule = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(json))
            #expect(rule.id.isUserOverride)
            #expect(rule.match.bundleIds == [bundle])
        }
    }

    @Test func ruleIDsAreValidForAnyBundleKey() {
        let hashed = BundleKey.executable(sha256Hex: String(repeating: "ab", count: 32))!
        #expect(
            CompatibilityModeChoice.ruleID(for: hashed).rawValue == "user.compat.sha256-"
                + String(repeating: "ab", count: 32))
        let long = BundleKey(rawValue: String(repeating: "a.", count: 100) + "b")!
        let id = CompatibilityModeChoice.ruleID(for: long)
        #expect(id.rawValue.utf8.count <= 128)
        #expect(!id.rawValue.hasSuffix("."))
        let dashes = BundleKey(rawValue: "com..example")!
        #expect(CompatibilityModeChoice.ruleID(for: dashes).rawValue == "user.compat.com.example")
    }

    @Test func foreignOverridesAreNotCompatibilityModes() {
        #expect(CompatibilityModeChoice(overrideRule: .object(["id": .string("user.ignore.1")])) == nil)
        let plain = JSONValue.object([
            "id": .string("user.compat.x"), "action": .object(["strategy": .string("backspaceReplace")]),
        ])
        #expect(CompatibilityModeChoice(overrideRule: plain) == nil)
        let ax = JSONValue.object([
            "id": .string("user.compat.x"), "action": .object(["strategy": .string("axReplace")]),
        ])
        #expect(CompatibilityModeChoice(overrideRule: ax) == nil)
    }
}

@Suite struct AppsPaneModelTests {
    let chat = BundleKey(rawValue: "com.example.Chat")!
    let term = BundleKey(rawValue: "com.example.Term")!
    let editor = BundleKey(rawValue: "com.example.Editor")!
    let now = Date(timeIntervalSince1970: 1_794_528_000)

    @Test func rowsKeepMemoryOrderAndAddOverrideOnlyApps() throws {
        let modes = AppModesDocument(
            globalMode: .vietnamese,
            apps: [
                AppModeEntry(bundle: term, rule: nil, mode: .english),
                AppModeEntry(bundle: chat, rule: .alwaysVietnamese, mode: nil),
                AppModeEntry(bundle: term, rule: .ignore, mode: nil),  // duplicate ignored
            ])
        let older = try #require(CompatibilityModeChoice.typeSlower.overrideRule(for: chat, date: "2026-11-01"))
        let newer = try #require(CompatibilityModeChoice.pasteText.overrideRule(for: chat, date: "2026-11-12"))
        let editorOverride = try #require(CompatibilityModeChoice.selectThenType.overrideRule(for: editor, date: "d"))
        let overrides = [
            StoredRuleOverride(createdAt: now.addingTimeInterval(-100), rule: older),
            StoredRuleOverride(createdAt: now, rule: newer),
            StoredRuleOverride(createdAt: now, rule: editorOverride),
            StoredRuleOverride(createdAt: now, rule: .string("junk")),
        ]
        let rows = AppsPaneModel.rows(appModes: modes, overrides: overrides, matrix: nil, today: now)
        #expect(rows.map(\.bundle) == [term, chat, editor])
        #expect(rows[0].rule == .remember)
        #expect(rows[0].rememberedMode == .english)
        #expect(rows[0].compatibilityMode == .automatic)
        #expect(rows[1].rule == .alwaysVietnamese)
        #expect(rows[1].compatibilityMode == .pasteText)  // newest wins
        #expect(rows[2].rule == .remember)
        #expect(rows[2].compatibilityMode == .selectThenType)
        #expect(rows.allSatisfy { $0.status == .notVerified && $0.note == nil })
        #expect(rows[1].id == chat)
    }

    @Test func emptyInputsGiveNoRows() throws {
        let matrix = try JSONDecoder().decode(
            MatrixDocument.self, from: Data(#"{"schemaVersion":1,"entries":[]}"#.utf8))
        #expect(AppsPaneModel.rows(appModes: AppModesDocument(), overrides: [], matrix: matrix, today: now).isEmpty)
    }
}

@Suite struct AppsPaneMatrixStatusTests {
    let chrome = BundleKey(rawValue: "com.example.Browser")!
    let term = BundleKey(rawValue: "com.example.Term")!
    let mirror = BundleKey(rawValue: "com.example.Mirror")!
    let now = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    func matrix() -> MatrixDocument {
        MatrixDocument(
            schemaVersion: 1,
            entries: [
                // A web-app row listed first must not decide the app's status (scoped rows are detail only).
                MatrixEntry(
                    bundleId: chrome, displayName: "Sheets in Browser", category: "office", status: .knownLimitation,
                    lastVerified: "2026-11-01", scope: .webApp),
                MatrixEntry(
                    bundleId: chrome, displayName: "Browser", category: "browser", status: .worksWithNotes,
                    note: LocalizedNote(vi: "Ghi chú", en: "Note"), lastVerified: "2026-10-20"),
                MatrixEntry(
                    bundleId: term, displayName: "Term", category: "terminal", status: .works,
                    lastVerified: "2026-05-01"),
                MatrixEntry(
                    bundleId: term, displayName: "tmux", category: "terminal", status: .works,
                    lastVerified: "2026-11-01",
                    scope: .inApp),
                MatrixEntry(
                    bundleId: mirror, displayName: "Mirror", category: "system", status: .knownLimitation,
                    note: LocalizedNote(vi: "Không gửi phím được.", en: "Keys cannot be sent."),
                    lastVerified: "2026-11-10",
                    scope: .app),
            ])
    }

    func rows() -> [AppsPaneRow] {
        let modes = AppModesDocument(apps: [
            AppModeEntry(bundle: chrome, mode: .vietnamese), AppModeEntry(bundle: term, rule: .alwaysEnglish),
            AppModeEntry(bundle: mirror),
        ])
        return AppsPaneModel.rows(appModes: modes, overrides: [], matrix: matrix(), today: now)
    }

    @Test func statusComesFromTheAppRowAfterThe120DayRule() {
        let rows = rows()
        #expect(rows.map(\.status) == [.worksWithNotes, .notVerified, .knownLimitation])  // term: 196 days old
        #expect(rows[0].note == LocalizedNote(vi: "Ghi chú", en: "Note"))
        #expect(rows[0].matrixDisplayName == "Browser")
        #expect(rows[2].noteText(.english) == "Keys cannot be sent.")
        #expect(rows[2].noteText(.vietnamese) == "Không gửi phím được.")
        #expect(rows[1].noteText(.vietnamese) == nil)
        let unknown = AppsPaneModel.rows(
            appModes: AppModesDocument(apps: [AppModeEntry(bundle: BundleKey(rawValue: "com.example.New")!)]),
            overrides: [], matrix: matrix(), today: now)
        #expect(unknown.first?.status == .notVerified && unknown.first?.matrixDisplayName == nil)
    }

    @Test func scopedRowsAppearOnlyInTheDetailView() {
        let rows = rows()
        let browser = AppDetail(row: rows[0], matrix: matrix(), today: now)
        #expect(browser.scoped.map(\.entry.displayName) == ["Sheets in Browser"])
        #expect(browser.scoped.map(\.status) == [.knownLimitation])
        #expect(browser.lastVerified == "2026-10-20")
        let term = AppDetail(row: rows[1], matrix: matrix(), today: now)
        #expect(term.scoped.map(\.entry.displayName) == ["tmux"])
        #expect(AppDetail(row: rows[2], matrix: nil, today: now).scoped.isEmpty)
    }

    @Test func labelsAndSymbolsForEveryValue() {
        #expect(
            PerAppRule.allCases.map(\.appsTitle) == [
                .ruleRemember, .ruleAlwaysEnglish, .ruleAlwaysVietnamese, .ruleIgnore,
            ])
        #expect(
            MatrixStatus.allCases.map(\.appsTitle) == [
                .statusWorks, .statusWorksWithNotes, .statusNotVerified, .statusKnownLimitation,
            ])
        // PRD-R67: each status has its own symbol besides the text, never colour alone.
        #expect(Set(MatrixStatus.allCases.map(\.symbolName)).count == MatrixStatus.allCases.count)
        let rows = rows()
        #expect(rows.map(\.rememberedModeTitle) == [.modeVietnamese, .modeNone, .modeNone])
        var english = rows[0]
        english.rememberedMode = .english
        #expect(english.rememberedModeTitle == .modeEnglish)
        #expect(
            CompatibilityModeChoice.allCases.map(\.title) == [
                .compatAutomatic, .compatTypeSlower, .compatSelectThenType, .compatPasteText,
            ])
        #expect(
            CompatibilityModeChoice.allCases.map(\.explanation) == [
                .compatAutomaticExplanation, .compatTypeSlowerExplanation, .compatSelectThenTypeExplanation,
                .compatPasteTextExplanation,
            ])
        // PRD-R36: at most three plain choices besides automatic; only paste needs the clipboard explanation.
        #expect(CompatibilityModeChoice.allCases.filter { $0 != .automatic }.count <= 3)
        #expect(CompatibilityModeChoice.allCases.filter(\.needsClipboardExplanation) == [.pasteText])
    }

    @Test func choicesBecomeAddOrRemoveCommands_PLTR540() throws {
        let utc = TimeZone(identifier: "UTC")!
        let added = CompatibilityModeChoice.typeSlower.command(for: term, at: now, timeZone: utc)
        guard case .add(let stored) = added else {
            Issue.record("expected an override")
            return
        }
        #expect(stored.createdAt == now)
        #expect(stored.rule["provenance"]?["date"] == .string("2026-11-13"))
        #expect(
            CompatibilityModeChoice.automatic.command(for: term, at: now)
                == .remove(CompatibilityModeChoice.ruleID(for: term)))
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(CompatibilityModeChoice.day(now.addingTimeInterval(-3_600), timeZone: tokyo) == "2026-11-13")
        #expect(CompatibilityModeChoice.day(now.addingTimeInterval(-3_600), timeZone: utc) == "2026-11-12")
    }
}
