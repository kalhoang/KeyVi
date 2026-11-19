// SPDX-License-Identifier: GPL-3.0-or-later
//
// The never-correct list in the store (03-product.md PRD-R81 storage half, spec/01-engine.md ENG-R1118, 1.1.0): kept
// next to the keep lists under `englishRestoreLists.neverCorrect`, lowercase ASCII letters only, cleared by the Typing
// pane reset and the full reset, exported and imported with the settings without a choice of its own (PRD-R72). A
// file or an export written by 1.0.x has neither the list nor D30: it loads with D30 on and an empty list and reports
// nothing as changed for them. A file written by 1.1.0 keeps both through a rewrite by 1.0.1, because both sit where
// every 1.0.x build keeps the keys it does not know (PLT-R1002). Schema version 1 stays.

import AppModel
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

private func object(_ text: String) throws -> [String: JSONValue] {
    try JSONSupport.parseObject(Data(text.utf8))
}

private let exportDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A settings export as 1.0.1 writes it: no `typoCorrection`, no `neverCorrect`.
private let releasedExport = Data(
    #"""
    {"kind": "settings-export", "schemaVersion": 1, "writtenBy": "1.0.1", "exportedAt": "2026-11-18T00:00:00Z",
     "settings": {"settings": {"typingMethod": "vni"},
                  "englishRestoreLists": {"keepAsTyped": ["tex"], "keepVietnamese": [], "learnedWords": []},
                  "optedInRules": [], "onboarding": {"completedVersion": "1.0.1"}},
     "ruleOverrides": []}
    """#.utf8)

@Suite struct NeverCorrectListModelTests {
    /// PRD-R81, ENG-R1118: one rule for the restore key, the field in Settings and an import (`NeverCorrectEntry`).
    @Test func neverCorrectNormalisesAndRefuses() {
        var user = UserSettings()
        let added = user.neverCorrect(" Androdi ")
        let again = user.neverCorrect("androdi")
        #expect(added)
        #expect(again, "a word already on the list is accepted and kept once")
        for refused in ["android1", "well-known", "việt", "", "two words", String(repeating: "a", count: 65)] {
            let accepted = user.neverCorrect(refused)
            #expect(!accepted, "\(refused.count) characters")
        }
        #expect(user.neverCorrect == ["androdi"])
        #expect(user.keepAsTyped.isEmpty && user.keepVietnamese.isEmpty && user.learnedWords.isEmpty)
    }
}

@Suite struct NeverCorrectListCodecTests {
    @Test func codecRoundTripsTheListUnderEnglishRestoreLists() {
        var user = UserSettings()
        user.keepAsTyped = ["tex"]
        user.neverCorrect = ["gramar", "androdi"]
        let encoded = SettingsCodec.encode(user, over: [:])
        #expect(encoded["englishRestoreLists"]?["neverCorrect"] == .array([.string("androdi"), .string("gramar")]))
        #expect(encoded["neverCorrect"] == nil && encoded["settings"]?["neverCorrect"] == nil)
        #expect(SettingsCodec.decode(encoded) == user)
    }

    /// An entry that `NeverCorrectEntry` refuses is dropped on load, listed for the import summary by position (never
    /// its text) and left out of the next rewrite; one bad entry never discards its siblings.
    @Test func invalidEntriesAreDroppedOnLoad() throws {
        let tooLong = String(repeating: "a", count: 65)
        let raw = try object(
            #"{"englishRestoreLists": {"neverCorrect": ["Androdi", " gramar ", "android1", "well-known", "việt", "", 7, "\#(tooLong)"]}}"#
        )
        let user = SettingsCodec.decode(raw)
        #expect(user.neverCorrect == ["androdi", "gramar"])
        #expect(
            SettingsCodec.skippedPaths(in: raw) == (2...7).map { "englishRestoreLists.neverCorrect[\($0)]" })
        #expect(
            SettingsCodec.encode(user, over: raw)["englishRestoreLists"]?["neverCorrect"]
                == .array([.string("androdi"), .string("gramar")]))
    }

    /// PLT-R1002 in both directions. This build keeps the keys it does not know inside `settings` and
    /// `englishRestoreLists`; a 1.0.x build keeps `typoCorrection` and `neverCorrect` the same way, because they sit in
    /// those two objects and its writer overlays them exactly as this one does (the code of both levels is the
    /// 1.0.1 code), so a 1.1.0 file rewritten by 1.0.1 still has the list and D30 when 1.1.0 reads it again.
    @Test func unknownSiblingKeysSurviveARewrite_PLTR1002() throws {
        let raw = try object(
            #"""
            {"settings": {"typoCorrection": false, "v2Setting": 1},
             "englishRestoreLists": {"keepAsTyped": [], "neverCorrect": ["androdi"], "v2List": ["x"]}}
            """#)
        var user = SettingsCodec.decode(raw)
        #expect(user.typoCorrection == .set(false))
        #expect(user.neverCorrect == ["androdi"])
        user.keepAsTyped = ["tex"]
        let rewritten = SettingsCodec.encode(user, over: raw)
        #expect(rewritten["englishRestoreLists"]?["v2List"] == .array([.string("x")]))
        #expect(rewritten["settings"]?["v2Setting"] == .number(1))
        #expect(rewritten["settings"]?["typoCorrection"] == .bool(false))
        #expect(rewritten["englishRestoreLists"]?["neverCorrect"] == .array([.string("androdi")]))
        #expect(SettingsCodec.decode(rewritten).neverCorrect == ["androdi"])
    }
}

@Suite struct NeverCorrectListStoreTests {
    /// Review Focus 3 of the plan: the released 1.0 settings file has neither key. It loads with D30 on (unset, so
    /// the shipped default applies, PRD-R6) and an empty list, names neither as explicitly set, and a rewrite keeps D30
    /// unset on disk and adds the empty list next to the keep lists, keeping the unknown sibling.
    @Test func aFileWithoutTheListLoadsEmptyAndWithD30On() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, SchemaFixtures.v1.settings)
        let state = await harness.store.load()
        #expect(state.user.neverCorrect.isEmpty && state.effective.neverCorrect.isEmpty)
        #expect(state.user.typoCorrection == .unset && state.effective.typoCorrection)
        #expect(!state.user.explicitlySetKeys.contains("neverCorrect"))
        #expect(!state.user.explicitlySetKeys.contains("typoCorrection"))
        #expect(state.notices.isEmpty)
        await harness.store.updateSettings { $0.keepAsTyped.insert("tar") }
        await harness.store.flush()
        let written = try #require(harness.object(.settings))
        #expect(written["settings"]?["typoCorrection"] == nil)
        #expect(written["englishRestoreLists"]?["neverCorrect"] == .array([]))
        #expect(written["englishRestoreLists"]?["futureList"] == .array([.number(1)]))
        #expect(written["schemaVersion"] == .number(1))
    }

    @Test func theListIsSavedAndReadBack() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.updateSettings { _ = $0.neverCorrect("Androdi") }
        await harness.store.flush()
        #expect(harness.object(.settings)?["englishRestoreLists"]?["neverCorrect"] == .array([.string("androdi")]))
        let next = SettingsStoreHarness(reusing: harness)
        let state = await next.store.load()
        #expect(state.user.neverCorrect == ["androdi"] && state.effective.neverCorrect == ["androdi"])
    }

    /// PRD-R26, PRD-R81: the Typing pane reset and the full reset clear the list like the keep lists; the other panes
    /// leave it.
    @Test func typingResetAndFullResetClearTheList_PRDR26() async {
        let clearing: [ResetScope] = [.typing, .all(includeMacros: false), .all(includeMacros: true)]
        for scope in clearing {
            let harness = SettingsStoreHarness()
            _ = await harness.store.load()
            await harness.store.updateSettings {
                _ = $0.neverCorrect("androdi")
                $0.typoCorrection = .set(false)
            }
            await harness.store.reset(scope)
            let state = await harness.store.state
            #expect(state.user.neverCorrect.isEmpty, "\(scope)")
            #expect(state.user.typoCorrection == .unset, "\(scope)")
            #expect(harness.object(.settings)?["englishRestoreLists"]?["neverCorrect"] == .array([]), "\(scope)")
        }
        let keeping: [ResetScope] = [.general, .apps, .macros(includeList: true)]
        for scope in keeping {
            let harness = SettingsStoreHarness()
            _ = await harness.store.load()
            await harness.store.updateSettings { _ = $0.neverCorrect("androdi") }
            await harness.store.reset(scope)
            #expect(await harness.store.state.user.neverCorrect == ["androdi"], "\(scope)")
        }
    }

    /// PRD-R72, PRD-R81: the list travels in the settings section, so every export carries it whatever is unticked,
    /// and the import applies it with the settings (no checkbox of its own); `changedKeys` names it only when it
    /// differs.
    @Test func exportThenImportCarriesTheListWithoutAChoice_PRDR72() async throws {
        let source = SettingsStoreHarness()
        _ = await source.store.load()
        await source.store.updateSettings { _ = $0.neverCorrect("androdi") }
        let lean = ExportOptions(includeMacros: false, includeAppModes: false, includeCollisionMemory: false)
        for options in [ExportOptions(), lean] {
            let exported = try JSONSupport.parseObject(try await source.store.export(options, now: exportDate))
            #expect(exported["settings"]?["englishRestoreLists"]?["neverCorrect"] == .array([.string("androdi")]))
        }
        let data = try await source.store.export(ExportOptions(), now: exportDate)

        let target = SettingsStoreHarness()
        _ = await target.store.load()
        let preview = try await target.store.previewImport(data)
        #expect(preview.changedSettingKeys == ["neverCorrect"])
        #expect(preview.skippedFields.isEmpty)
        try await target.store.applyImport(preview, choices: ImportChoices(applySettings: false))
        #expect(await target.store.state.user.neverCorrect.isEmpty, "the list goes with the settings")
        try await target.store.applyImport(preview, choices: ImportChoices())
        #expect(await target.store.state.user.neverCorrect == ["androdi"])
        #expect(try await target.store.previewImport(data).changedSettingKeys.isEmpty)
    }

    /// Review Focus 3: an export of 1.0.x has neither key. Into a store at the defaults it changes nothing for them
    /// and D30 resolves on. Into a store that has a list, the import replaces the settings as it replaces the keep
    /// lists, and the summary names the list (the files are backed up first, PLT-R1010).
    @Test func a1_0ExportImportsWithTheDefaults() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let preview = try await harness.store.previewImport(releasedExport)
        #expect(preview.changedSettingKeys == ["typingMethod", "keepAsTyped"])
        #expect(preview.skippedFields.isEmpty)
        try await harness.store.applyImport(preview, choices: ImportChoices())
        let state = await harness.store.state
        #expect(state.user.typoCorrection == .unset && state.effective.typoCorrection)
        #expect(state.user.neverCorrect.isEmpty)

        let withList = SettingsStoreHarness()
        _ = await withList.store.load()
        await withList.store.updateSettings { _ = $0.neverCorrect("androdi") }
        #expect(try await withList.store.previewImport(releasedExport).changedSettingKeys.contains("neverCorrect"))
    }

    /// Migrations.swift: settings.json stays at schema version 1 (an older file reads as an empty list), so no
    /// migration step ships and 1.0.x keeps reading the files 1.1.0 writes.
    @Test func settingsStayAtSchemaVersionOne() throws {
        #expect(SettingsFile.settings.currentSchemaVersion == 1)
        #expect(throws: Never.self) { try MigrationChain.shipped.migrate([:], file: .settings, from: 1, to: 1) }
    }
}
