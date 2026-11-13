// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

private func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

private let exportDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A store with every kind of content, loaded from the v1 fixture plus a few explicit changes.
private func populated() async -> SettingsStoreHarness {
    let harness = SettingsStoreHarness()
    harness.seed(.settings, SchemaFixtures.v1.settings)
    harness.seed(.appModes, SchemaFixtures.v1.appModes)
    harness.seed(.ruleOverrides, SchemaFixtures.v1.ruleOverrides)
    harness.seed(.macros, SchemaFixtures.v1.macros)
    _ = await harness.store.load()
    await harness.store.updateSettings {
        $0.englishRestore = .set(true)  // set to the default value: must stay set (PRD-R6)
        $0.onboarding.completedVersion = nil
    }
    return harness
}

/// The user-visible content of a state (generation and notices differ between stores by design).
private struct Content: Equatable {
    var user: UserSettings
    var effective: EffectiveSettings
    var appModes: AppModesDocument
    var ruleOverrides: [StoredRuleOverride]
    var macros: [StoredMacro]
}

private func comparable(_ state: SettingsState) -> Content {
    Content(
        user: state.user, effective: state.effective, appModes: state.appModes, ruleOverrides: state.ruleOverrides,
        macros: state.macros)
}

@Suite struct SettingsExportTests {
    @Test func fileNameUsesSlugAndLocalDatePLTR1010() {
        #expect(
            ExportOptions.fileName(slug: "app", date: exportDate, timeZone: TimeZone(identifier: "UTC")!)
                == "app-settings-20270115.json")
        #expect(
            ExportOptions.fileName(
                slug: "app", date: exportDate.addingTimeInterval(57_600),
                timeZone: TimeZone(identifier: "Asia/Ho_Chi_Minh")!) == "app-settings-20270116.json")
        #expect(ExportOptions.fileName(slug: "x", date: exportDate).hasPrefix("x-settings-2027011"))
    }

    @Test func exportShapeAndUntickedSectionsPRDR72() async throws {
        let harness = await populated()
        let full = try JSONSupport.parseObject(try await harness.store.export(ExportOptions(), now: exportDate))
        #expect(full["kind"] == .string("settings-export"))
        #expect(full["schemaVersion"] == .number(1))
        #expect(full["writtenBy"] == .string("0.1.0"))
        #expect(full["exportedAt"] == .string("2027-01-15T08:00:00Z"))
        #expect(full["settings"]?["settings"]?["typingMethod"] == .string("vni"))
        #expect(full["settings"]?["settings"]?["futureSettingFromNewerBuild"] == nil)
        #expect(arrayItems(full["appModes"]?["apps"]).count == 4)  // PRD-R23: memory is exported
        #expect(arrayItems(full["ruleOverrides"]).count == 1)  // PLT-R541
        #expect(arrayItems(full["macros"]).count == 2)
        let lean = try JSONSupport.parseObject(
            try await harness.store.export(ExportOptions(includeMacros: false, includeAppModes: false), now: exportDate)
        )
        #expect(lean["macros"] == nil && lean["appModes"] == nil)
        #expect(lean["ruleOverrides"] != nil && lean["settings"] != nil)
    }

    /// Export on v1 then import into a fresh store reproduces the same state.
    @Test func exportThenImportReproducesTheState() async throws {
        let source = await populated()
        let data = try await source.store.export(ExportOptions(), now: exportDate)
        let target = SettingsStoreHarness()
        _ = await target.store.load()
        let preview = try await target.store.previewImport(data)
        #expect(preview.schemaVersion == 1)
        #expect(preview.skippedFields.isEmpty)
        #expect(preview.appEntries == 4 && preview.ruleOverrides == 1)
        #expect(preview.macros?.new.count == 2)
        #expect(
            preview.changedSettingKeys.contains("typingMethod") && preview.changedSettingKeys.contains("englishRestore")
        )
        try await target.store.applyImport(preview, choices: ImportChoices())
        let imported = await target.store.state
        #expect(comparable(imported) == comparable(await source.store.state))
        // And it is on disk: a relaunch reads the same.
        let relaunch = SettingsStoreHarness(reusing: target)
        #expect(comparable(await relaunch.store.load()) == comparable(imported))
    }

    @Test func onboardingIsNeverImported() async throws {
        let source = SettingsStoreHarness()
        _ = await source.store.load()
        await source.store.updateSettings { $0.onboarding.completedVersion = "0.1.0" }
        let data = try await source.store.export(ExportOptions(), now: exportDate)
        let target = SettingsStoreHarness()
        _ = await target.store.load()
        try await target.store.applyImport(try await target.store.previewImport(data), choices: ImportChoices())
        #expect(await target.store.state.user.onboarding.completedVersion == nil)
    }
}

@Suite struct SettingsImportTests {
    private func export(_ body: String, version: Int = 1) -> Data {
        Data(
            #"{"kind":"settings-export","schemaVersion":\#(version),"writtenBy":"9.9","exportedAt":"2030-01-01T00:00:00Z"\#(body)}"#
                .utf8)
    }

    /// PLT-R1010, PRD-R72: a newer export is imported for known fields; the rest is listed.
    @Test func newerSchemaListsSkippedFields() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let data = export(
            #","settings":{"settings":{"typingMethod":"vni","v2Setting":true},"v2List":[]},"appModes":{"globalMode":"en","apps":[{"bundle":"a.a","mode":"en"},{"bundle":"bad!"}],"v2":1},"ruleOverrides":[{"createdAt":"x","rule":{}}],"cloudSync":{}"#,
            version: 2)
        let preview = try await harness.store.previewImport(data)
        #expect(preview.schemaVersion == 2)
        #expect(
            preview.skippedFields == [
                "cloudSync", "settings.v2List", "settings.settings.v2Setting", "appModes.v2", "appModes.apps[1]",
                "ruleOverrides.overrides[0]",
            ])
        #expect(preview.changedSettingKeys == ["typingMethod"])
        try await harness.store.applyImport(preview, choices: ImportChoices())
        let state = await harness.store.state
        #expect(state.user.typingMethod == .set(.vni))
        #expect(state.appModes.apps == [AppModeEntry(bundle: bundle("a.a"), mode: .english)])
        #expect(harness.object(.settings)?["settings"]?["v2Setting"] == nil)
    }

    @Test func olderExportIsMigrated() async throws {
        let harness = SettingsStoreHarness(migrations: TestMigrations.chain)
        _ = await harness.store.load()
        let data = export(
            #","settings":{"prefs":{"method":"vni"}},"macros":[{"trigger":"vn","expansion":"Việt Nam"}]"#, version: 0)
        let preview = try await harness.store.previewImport(data)
        #expect(preview.changedSettingKeys == ["typingMethod"])
        #expect(preview.macros?.new.map(\.trigger) == ["vn"])
        let unmigratable = SettingsStoreHarness()
        _ = await unmigratable.store.load()
        await #expect(throws: SettingsImportError.migrationFailed(fromVersion: 0)) {
            try await unmigratable.store.previewImport(data)
        }
    }

    @Test func applyBacksUpCurrentFilesFirstAndHonoursChoices() async throws {
        let harness = await populated()
        await harness.store.flush()
        let data = export(
            #","settings":{"settings":{"typingMethod":"telex"}},"appModes":{"globalMode":"vi","apps":[{"bundle":"com.example.Chat","mode":"en"},{"bundle":"new.app","rule":"ignore"}]},"ruleOverrides":[{"createdAt":"2027-01-01T00:00:00Z","rule":{"id":"user.paste.1","strategy":"axReplace"}},{"createdAt":"2027-01-01T00:00:00Z","rule":{"id":"user.other"}}],"macros":[{"trigger":"VN","expansion":"VIỆT NAM"},{"trigger":"kg","expansion":"không"}]"#
        )
        let preview = try await harness.store.previewImport(data)
        #expect(preview.macros?.duplicates.count == 1 && preview.macros?.new.count == 1)
        harness.spy.resetCalls()
        try await harness.store.applyImport(
            preview, choices: ImportChoices(applySettings: false, macroDuplicates: .useImported))
        let firstWrites = harness.spy.mutatingCalls.filter { $0.operation == .writeAtomically }.map(\.path)
        #expect(firstWrites.prefix(3).allSatisfy { $0.contains("/backups/") })
        let state = await harness.store.state
        #expect(state.user.typingMethod == .set(.vni))  // settings not applied
        #expect(state.appModes.globalMode == .vietnamese)
        #expect(state.appModes.apps.first == AppModeEntry(bundle: bundle("com.example.Chat"), mode: .english))
        #expect(state.appModes.apps.contains(AppModeEntry(bundle: bundle("new.app"), rule: .ignore)))
        #expect(state.appModes.apps.contains { $0.bundle == bundle("com.example.Terminal") })
        #expect(state.ruleOverrides.map { $0.rule["strategy"] } == [.string("axReplace"), nil])
        #expect(state.macros.map(\.expansion) == ["VIỆT NAM", "pa@example.com", "không"])
    }

    @Test func keepMineAndSkippingMacros() async throws {
        let harness = await populated()
        let data = export(#","macros":[{"trigger":"vn","expansion":"other"},{"trigger":"vn.","expansion":"shadowed"}]"#)
        let preview = try await harness.store.previewImport(data)
        #expect(preview.macros?.invalid.map(\.issue) == [.shadowedBy(shorter: "vn")])
        try await harness.store.applyImport(preview, choices: ImportChoices(macroDuplicates: .keepMine))
        #expect(await harness.store.state.macros.first?.expansion == "Việt Nam")
        let generation = await harness.store.state.generation
        try await harness.store.applyImport(preview, choices: ImportChoices(applyMacros: false))
        #expect(await harness.store.state.generation == generation)
    }

    /// PLT-R912: untrusted files are rejected with a reason and never crash.
    @Test func malformedFilesAreRejectedWithAReason() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let cases: [(Data, SettingsImportError)] = [
            (Data(count: 6 * 1024 * 1024), .tooLarge(limit: 5 * 1024 * 1024)),
            (
                Data((String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)).utf8),
                .tooDeeplyNested(limit: 64)
            ),
            (
                Data(
                    (#"{"kind":"settings-export","schemaVersion":1,"settings":"#
                        + String(repeating: #"{"a":"#, count: 100)).utf8), .tooDeeplyNested(limit: 64)
            ),
            (Data("garbage".utf8), .notJSON),
            (Data(), .notJSON),
            (Data("[1]".utf8), .notAnObject),
            (Data(#"{"kind":"other","schemaVersion":1}"#.utf8), .notASettingsExport),
            (Data(#"{"macros":[]}"#.utf8), .notASettingsExport),
            (Data(#"{"kind":"settings-export"}"#.utf8), .invalidSchemaVersion),
            (Data(#"{"kind":"settings-export","schemaVersion":1.5}"#.utf8), .invalidSchemaVersion),
            (export(#","settings":[]"#), .invalidSection("settings")),
            (export(#","appModes":1"#), .invalidSection("appModes")),
            (export(#","ruleOverrides":{}"#), .invalidSection("ruleOverrides")),
            (export(#","macros":"x""#), .invalidSection("macros")),
        ]
        for (data, expected) in cases {
            await #expect(throws: expected) { try await harness.store.previewImport(data) }
        }
    }

    @Test func randomBytesNeverCrashImport() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        var generator = SeededGenerator(seed: 0xF022)
        let seeds = [Data(#"{"kind":"settings-export","schemaVersion":1,"settings":{"settings":{}}}"#.utf8)]
        for iteration in 0..<300 {
            var bytes = [UInt8](seeds[0])
            if iteration % 3 == 0 {
                bytes = (0..<Int.random(in: 0...512, using: &generator)).map { _ in
                    UInt8.random(in: 0...255, using: &generator)
                }
            } else {
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(
                        in: 0...255, using: &generator)
                }
            }
            do {
                let preview = try await harness.store.previewImport(Data(bytes))
                try await harness.store.applyImport(preview, choices: ImportChoices())
            } catch is SettingsImportError {
                continue
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }
}
