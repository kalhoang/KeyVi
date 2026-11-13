// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Settings window's writes against a real SettingsStore over in-memory fakes: explicit edits (PRD-R6,
// PRD-R27), per-app rules (PRD-R21), compatibility overrides in rule-overrides.json (PLT-R540, PLT-R541), resets
// that keep macros unless ticked (PRD-R26), import summary and apply (PLT-R1010), notices (PLT-R1006, PLT-R1009).

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct SettingsCommandsTests {
    let chat = BundleKey(rawValue: "com.example.Chat")!
    let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    func loaded() async -> (SettingsStoreHarness, SettingsCommands) {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        return (harness, SettingsCommands(store: harness.store))
    }

    @Test func editsApplyAtOnceAndAreWrittenAsExplicitChoices() async throws {
        let (harness, commands) = await loaded()
        let state = await commands.apply(.typingMethod(.vni))
        #expect(state.effective.typingMethod == .vni)  // PRD-R27: visible before the debounced write
        _ = await commands.apply(.englishRestore(true))  // equal to D4, still explicit (PRD-R6)
        await harness.advance(by: .seconds(2))
        let settings = try #require(harness.object(.settings)?["settings"]?.objectValue)
        #expect(settings["typingMethod"] == .string("vni"))
        #expect(settings["englishRestore"] == .bool(true))
        #expect(settings["tonePlacement"] == nil)  // untouched stays unset
        let current = await commands.state()
        #expect(current.user.explicitlySetKeys == ["typingMethod", "englishRestore"])
    }

    @Test func rulesFromTheAppsPaneAreSetAndRememberClearsThem() async {
        let (_, commands) = await loaded()
        var state = await commands.setRule(.alwaysEnglish, for: chat)
        #expect(state.appModes.apps == [AppModeEntry(bundle: chat, rule: .alwaysEnglish)])
        state = await commands.setRule(.remember, for: chat)
        #expect(state.appModes.apps.isEmpty)
    }

    @Test func compatibilityChoicesWriteAndRemoveTheUserOverride_PLTR540() async throws {
        let (harness, commands) = await loaded()
        var state = await commands.setCompatibility(.selectThenType, for: chat, at: date)
        #expect(state.ruleOverrides.count == 1)
        await harness.advance(by: .seconds(2))
        let overrides = try #require(items(harness.object(.ruleOverrides)?["overrides"]))
        #expect(overrides.count == 1)
        let rule = try #require(overrides.first?["rule"])
        #expect(rule["id"] == .string("user.compat.com.example.Chat"))
        #expect(rule["action"] == .object(["strategy": .string("selectReplace")]))
        #expect(rule["match"]?["bundleIds"] == .array([.string("com.example.Chat")]))

        // A new choice replaces the same rule id; the row shows "set by you on <date>" (PLT-R541).
        state = await commands.setCompatibility(.pasteText, for: chat, at: date.addingTimeInterval(60))
        #expect(state.ruleOverrides.count == 1)
        let row = AppsPaneModel.rows(
            appModes: state.appModes, overrides: state.ruleOverrides, matrix: nil, today: date)
        #expect(row.first?.compatibilityMode == .pasteText)
        #expect(row.first?.compatibilitySetOn == date.addingTimeInterval(60))
        // PLT-R460: choosing paste after the explanation is the opt-in, so no requiresUserOptIn is written.
        #expect(state.ruleOverrides.first?.rule["action"]?["requiresUserOptIn"] == nil)

        state = await commands.setCompatibility(.automatic, for: chat, at: date)
        #expect(state.ruleOverrides.isEmpty)
        await harness.advance(by: .seconds(2))
        #expect(items(harness.object(.ruleOverrides)?["overrides"]) == [])
    }

    @Test func globalResetKeepsMacrosUnlessTicked_PRDR26() async {
        let (_, commands) = await loaded()
        _ = await commands.apply(.typingMethod(.vni))
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        _ = await commands.setRule(.ignore, for: chat)

        var request = ResetRequest(target: .all)
        var state = await commands.perform(request.plan)
        #expect(state.user.typingMethod == .unset)
        #expect(state.appModes.apps.isEmpty)
        #expect(state.macros.map(\.trigger) == ["vn"])  // kept: checkbox not ticked

        request.deleteMacros = true
        state = await commands.perform(request.plan)
        #expect(state.macros.isEmpty)
    }

    @Test func paneResetsTouchOnlyTheirPane() async {
        let (_, commands) = await loaded()
        _ = await commands.apply(.typingMethod(.vni))
        _ = await commands.apply(.rememberPerApp(false))
        _ = await commands.apply(.macrosEnabled(false))
        _ = await commands.apply(.keepAsTyped(["text"]))
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])

        var state = await commands.perform(ResetRequest(target: .pane(.general)).plan)
        #expect(state.user.rememberPerApp == .unset)
        #expect(state.user.typingMethod == .set(.vni))

        state = await commands.perform(ResetRequest(target: .pane(.typing)).plan)
        #expect(state.user.typingMethod == .unset && state.user.keepAsTyped.isEmpty)

        var macros = ResetRequest(target: .pane(.macros))
        state = await commands.perform(macros.plan)
        #expect(state.user.macrosEnabled == .unset)
        #expect(state.macros.count == 1)  // PRD-R26
        macros.deleteMacros = true
        state = await commands.perform(macros.plan)
        #expect(state.macros.isEmpty)

        _ = await commands.setCompatibility(.typeSlower, for: chat, at: date)
        state = await commands.perform(ResetRequest(target: .pane(.apps)).plan)
        #expect(state.ruleOverrides.isEmpty)
    }

    @Test func macrosPaneResetBacksUpTheCurrentListBeforeDeletingIt_PRDR26_PLTR1006() async throws {
        // Every write backs up what it wrote (PLT-R1006); deleting the list from the Macros pane must still leave
        // the list as it was just before the reset recoverable.
        let (harness, commands) = await loaded()
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        await harness.advance(by: .seconds(2))
        _ = await commands.saveMacros([
            StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "dc", expansion: "được"),
        ])
        await harness.advance(by: .seconds(2))

        var request = ResetRequest(target: .pane(.macros))
        request.deleteMacros = true
        let state = await commands.perform(request.plan)
        await harness.advance(by: .seconds(2))
        #expect(state.macros.isEmpty)
        #expect(state.user.macrosEnabled == .unset)
        #expect(macroBackups(harness).contains { $0.contains("\"dc\"") && $0.contains("\"vn\"") })
        #expect(try #require(items(harness.object(.macros)?["macros"])).isEmpty)
    }

    @Test func macrosPaneResetWithoutTheBoxLeavesTheMacrosFileAlone() async {
        let (harness, commands) = await loaded()
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        await harness.advance(by: .seconds(2))
        let before = harness.paths
        let state = await commands.perform(ResetRequest(target: .pane(.macros)).plan)
        await harness.advance(by: .seconds(2))
        #expect(state.macros.count == 1)
        #expect(
            harness.paths.filter { $0.hasPrefix("backups/macros") } == before.filter { $0.hasPrefix("backups/macros") })
    }

    private func macroBackups(_ harness: SettingsStoreHarness) -> [String] {
        harness.paths.filter { $0.hasPrefix("backups/macros.json") }.compactMap { path in
            harness.memory.nodes[SettingsStoreHarness.directory.path + "/" + path]?.data.map {
                String(decoding: $0, as: UTF8.self)
            }
        }
    }

    @Test func importSummaryListsChangesAndSkippedFieldsThenApplies_PLTR1010() async throws {
        let (_, commands) = await loaded()
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        let file = """
            {"kind":"settings-export","schemaVersion":2,"writtenBy":"9.0",
             "settings":{"settings":{"typingMethod":"vni","futureOption":true}},
             "macros":[{"trigger":"vn","expansion":"Viet Nam"},{"trigger":"dc","expansion":"được"},
                       {"trigger":"bad key","expansion":"x"}],
             "cloud":{"x":1}}
            """
        var summary = ImportSummary(preview: try await commands.previewImport(Data(file.utf8)))
        let l = try Localizers()
        let lines = summary.lines(l.vi)
        #expect(lines.contains("Cài đặt sẽ đổi: Kiểu gõ."))
        #expect(lines.contains("Gõ tắt: 1 mới, 1 trùng, 1 không hợp lệ"))
        #expect(lines.contains { $0.hasPrefix("Bỏ qua vì phiên bản này chưa hiểu:") && $0.contains("cloud") })
        #expect(lines.contains(l.vi.string(SettingsText.importNewerSchema)))
        #expect(summary.isNewerSchema && summary.hasSettings && summary.hasMacros && summary.hasDuplicateMacros)
        #expect(!summary.hasAppModes && !summary.hasRuleOverrides)

        summary.choices.macroDuplicates = .useImported
        let state = try await commands.applyImport(summary)
        #expect(state.effective.typingMethod == .vni)
        #expect(Set(state.macros.map(\.trigger)) == ["vn", "dc"])
        #expect(state.macros.first { $0.trigger == "vn" }?.expansion == "Viet Nam")
    }

    @Test func emptySelectionAndUnchangedSettingsAreSaid() async throws {
        let (_, commands) = await loaded()
        let file =
            #"{"kind":"settings-export","schemaVersion":1,"settings":{},"appModes":{"apps":[]},"ruleOverrides":[]}"#
        var summary = ImportSummary(preview: try await commands.previewImport(Data(file.utf8)))
        let l = try Localizers()
        let lines = summary.lines(l.en)
        #expect(lines.first == "No settings will change.")
        #expect(lines.contains("Apps with rules or remembered choices: 0"))
        #expect(lines.contains("Compatibility modes: 0"))
        #expect(!summary.isNewerSchema && !summary.isEmptySelection)
        summary.choices = ImportChoices(applySettings: false, applyAppModes: false, applyRuleOverrides: false)
        #expect(summary.isEmptySelection)
    }

    @Test func refusedImportsAreExplained() async throws {
        let (_, commands) = await loaded()
        let l = try Localizers()
        await #expect(throws: SettingsImportError.notASettingsExport) {
            _ = try await commands.previewImport(Data(#"{"kind":"other"}"#.utf8))
        }
        let cases: [(SettingsImportError, String)] = [
            (.tooLarge(limit: 5 * 1024 * 1024), "Tệp này lớn hơn 5 MB."),
            (.notJSON, "Tệp này không đúng định dạng."),
            (.tooDeeplyNested(limit: 64), "Tệp này không đúng định dạng."),
            (.notAnObject, "Tệp này không đúng định dạng."),
            (.notASettingsExport, "Tệp này không phải tệp cài đặt xuất từ App."),
            (.invalidSchemaVersion, "Tệp này thiếu số phiên bản định dạng, hoặc số đó không hợp lệ."),
            (.invalidSection("macros"), "Phần \"macros\" trong tệp không đúng định dạng."),
            (.migrationFailed(fromVersion: 0), "Không chuyển đổi được tệp từ định dạng cũ 0."),
            (.unavailableInSafeMode, "App đang chạy ở chế độ an toàn. Hãy thoát chế độ an toàn rồi nhập lại."),
        ]
        for (error, text) in cases {
            #expect(SettingsImportMessage.text(for: error, appName: "App", l.vi) == text)
            #expect(SettingsImportMessage.text(for: error as any Error, appName: "App", l.vi) == text)
        }
        #expect(
            SettingsImportMessage.text(for: CocoaError(.fileReadNoPermission), appName: "App", l.vi)
                == "Không đọc được tệp này.")
    }

    @Test func importLimitAndSchemaVersionComeFromTheStore_PLTR912_PRDR72() async throws {
        // The window reads at most SettingsExportFormat.maxImportBytes + 1 bytes and calls a file "from a newer
        // version" above SettingsExportFormat.schemaVersion: the store's own public constants, so they cannot drift.
        let (_, commands) = await loaded()
        let limit = SettingsExportFormat.maxImportBytes
        let oversized = Data(repeating: 0x20, count: limit + 1)
        await #expect(throws: SettingsImportError.tooLarge(limit: limit)) {
            _ = try await commands.previewImport(oversized)
        }
        let atLimit = Data(repeating: 0x20, count: limit)
        await #expect(throws: SettingsImportError.notJSON) { _ = try await commands.previewImport(atLimit) }
        let data = try await commands.export(ExportOptions(includeMacros: true, includeAppModes: true), now: date)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(object["schemaVersion"] == .number(Double(SettingsExportFormat.schemaVersion)))
        let preview = try await commands.previewImport(data)
        #expect(!ImportSummary(preview: preview).isNewerSchema)
        let newer = #"{"kind":"settings-export","schemaVersion":\#(SettingsExportFormat.schemaVersion + 1)}"#
        #expect(ImportSummary(preview: try await commands.previewImport(Data(newer.utf8))).isNewerSchema)
        let l = try Localizers()
        #expect(
            SettingsImportMessage.text(for: .tooLarge(limit: limit), appName: "App", l.en)
                == "This file is larger than 5 MB.")
    }

    @Test func exportIsTheStoreExportWithTheChosenSections() async throws {
        let (_, commands) = await loaded()
        _ = await commands.saveMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        let data = try await commands.export(ExportOptions(includeMacros: false, includeAppModes: true), now: date)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(object["kind"] == .string("settings-export"))
        #expect(object["macros"] == nil && object["appModes"] != nil)
    }

    @Test func noticeActionsReachTheStore() async {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, "{ not json")
        let state = await harness.store.load()
        #expect(state.notices == [.corruptFileUsingDefaults(.settings)])
        let commands = SettingsCommands(store: harness.store)
        var after = await commands.perform(.useDefaults(.settings))
        #expect(after.notices.isEmpty)
        after = await commands.perform(.report)
        after = await commands.perform(.leaveSafeMode)
        #expect(!after.safeMode)
    }
}

private func items(_ value: JSONValue?) -> [JSONValue]? {
    if case .array(let items)? = value { return items }
    return nil
}
