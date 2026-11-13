// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R34 rows, PRD-R36 and PLT-R540 compatibility mode overrides. The matrix status path through
// MatrixStatusResolver (W1-C) is covered once that resolver is implemented (W2-B takes this file over).

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
