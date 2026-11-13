// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import Testing
import TestSupport

@testable import SettingsStore

private func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

private func seedRelease(_ release: SchemaFixtures.Release, in harness: SettingsStoreHarness) {
    harness.seed(.settings, release.settings)
    harness.seed(.appModes, release.appModes)
    harness.seed(.ruleOverrides, release.ruleOverrides)
    harness.seed(.macros, release.macros)
}

@Suite struct SettingsStoreFixtureTests {
    /// PLT-R1005, QA-R41: every released schema loads, migrates to the current one and keeps every choice.
    @Test func everyReleasedFixtureLoadsAndCompares() async throws {
        for release in SchemaFixtures.released {
            let harness = SettingsStoreHarness()
            seedRelease(release, in: harness)
            let state = await harness.store.load()
            #expect(state.notices.isEmpty)
            #expect(state.readOnlyFiles.isEmpty)
            #expect(state.user.typingMethod == .set(.vni))
            #expect(state.user.tonePlacement == .set(.traditional))
            #expect(state.user.restoreHotkey == .set(nil))
            #expect(state.user.toggleHotkey == .set(.keyCombo(modifiers: [.control, .command], keyCode: KeyCode(rawValue: 49))))
            #expect(state.user.layoutBinding.resolved(default: LayoutModeBinding()).enabled)
            #expect(state.user.englishRestore == .unset)
            #expect(state.user.keepAsTyped == ["tex"] && state.user.keepVietnamese == ["mas"])
            #expect(state.user.optedInRules == [RuleID(rawValue: "chromium.ax-enable")!])
            #expect(state.user.onboarding.completedVersion == "0.1.0")
            #expect(state.effective.typingMethod == .vni && state.effective.englishRestore)
            #expect(state.appModes.globalMode == .english)
            #expect(state.appModes.apps.count == 4)
            #expect(state.appModes.apps[2] == AppModeEntry(bundle: bundle("com.example.Editor"), rule: .ignore, mode: .vietnamese))
            #expect(state.ruleOverrides.map { $0.rule["id"] } == [.string("user.paste.1")])
            #expect(state.macros.map(\.trigger) == ["vn", "@@"])
            // Nothing to migrate: loading a current file never writes.
            #expect(harness.spy.mutatingCalls.isEmpty)
        }
    }

    @Test func olderSchemaIsBackedUpBeforeMigrationThenWrittenOncePLTR1005() async throws {
        let harness = SettingsStoreHarness(migrations: TestMigrations.chain)
        harness.seed(.settings, SchemaFixtures.v0Settings)
        let original = try #require(harness.data(.settings))
        let state = await harness.store.load()
        #expect(state.user.typingMethod == .set(.vni))
        #expect(state.user.englishRestore == .set(false))
        let writes = harness.spy.mutatingCalls.filter { $0.operation == .writeAtomically }.map(\.path)
        #expect(writes.count == 2)
        #expect(writes.first?.contains("/backups/settings.json.v0.") == true)
        #expect(writes.last == harness.url(.settings).path)
        let backupPath = try #require(harness.paths.first { $0.hasPrefix("backups/settings.json.v0.") })
        #expect(harness.memory.nodes["/Settings/" + backupPath]?.data == original)
        #expect(harness.memory.nodes["/Settings/" + backupPath]?.permissions == .ownerOnlyFile)
        let rewritten = try #require(harness.object(.settings))
        #expect(rewritten["schemaVersion"] == .number(1))
        #expect(rewritten["unknownFromV0"] == .array([.number(1), .number(2)]))
        #expect(rewritten["settings"]?["typingMethod"] == .string("vni"))
        // Runs once: the next launch finds version 1 and writes nothing.
        let next = SettingsStoreHarness(reusing: harness, migrations: TestMigrations.chain)
        _ = await next.store.load()
        #expect(next.spy.mutatingCalls.isEmpty)
    }

    @Test func aFailedPreMigrationBackupLeavesTheOriginalAlone() async throws {
        let harness = SettingsStoreHarness(migrations: TestMigrations.chain)
        harness.seed(.settings, SchemaFixtures.v0Settings)
        let original = harness.data(.settings)
        harness.spy.failAll(.writeAtomically)
        let state = await harness.store.load()
        #expect(state.user.typingMethod == .set(.vni))
        #expect(state.notices == [.writeFailed(.settings)])
        harness.spy.clearFailures()
        await harness.store.updateSettings { $0.soundOnSwitch = .set(true) }
        await harness.store.flush()
        #expect(harness.data(.settings) == original)
    }

    @Test func unmigratableOlderFileIsTreatedAsCorrupt() async {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, SchemaFixtures.v0Settings)
        let state = await harness.store.load()
        #expect(state.notices == [.corruptFileUsingDefaults(.settings)])
        #expect(harness.paths.contains { $0.hasPrefix("settings.json.corrupt-") })
    }
}

@Suite struct SettingsStoreRecoveryTests {
    private let truncated = #"{"schemaVersion": 1, "settings": {"typingMethod": "vn"#

    /// PLT-R1006 with a backup: quarantine, newest valid backup loaded, notice, no write before confirmation.
    @Test func truncatedFileRecoversFromTheNewestValidBackup() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, #"{"schemaVersion":1,"writtenBy":"0.1.0","settings":{"typingMethod":"vni"}}"#)
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.tonePlacement = .set(.modern) }
        await harness.advance(by: .seconds(1))  // first write of the session backs up the vni file
        harness.wallClock.advance(by: 60)
        await harness.store.updateSettings { $0.soundOnSwitch = .set(true) }
        await harness.store.flush()
        // A newer but unusable backup must be skipped.
        try harness.memory.writeAtomically(
            Data("garbage".utf8), to: URL(fileURLWithPath: "/Settings/backups/settings.json.v1.20990101T000000Z.json"),
            permissions: .ownerOnlyFile)
        harness.seed(.settings, truncated)

        harness.wallClock.advance(by: 60)
        let next = SettingsStoreHarness(reusing: harness)
        let state = await next.store.load()
        #expect(state.user.typingMethod == .set(.vni))
        #expect(state.user.tonePlacement == .unset)
        guard case .recoveredFromBackup(.settings, let date)? = state.notices.first else {
            Issue.record("expected a recovery notice, got \(state.notices)")
            return
        }
        #expect(date == harness.wallClock.now().addingTimeInterval(-120))
        #expect(next.paths.contains { $0.hasPrefix("settings.json.corrupt-") })
        #expect(next.data(.settings) == nil)

        next.spy.resetCalls()
        await next.store.updateSettings { $0.soundOnSwitch = .set(false) }
        await next.advance(by: .seconds(5))
        await next.store.flush()
        #expect(next.spy.mutatingCalls.isEmpty)

        await next.store.confirmDefaults(for: .settings)
        let confirmed = await next.store.state
        #expect(confirmed.notices.isEmpty)
        let written = try #require(next.object(.settings))
        #expect(written["settings"]?["typingMethod"] == .string("vni"))
        #expect(written["settings"]?["soundOnSwitch"] == .bool(false))
    }

    /// PLT-R1006 without a backup: defaults in memory, nothing written, notice; again at the next launch.
    @Test func corruptFileWithoutBackupUsesDefaultsAndWritesNothing() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.macros, "not json at all")
        let state = await harness.store.load()
        #expect(state.notices == [.corruptFileUsingDefaults(.macros)])
        #expect(state.macros.isEmpty)
        let writes = harness.spy.mutatingCalls
        #expect(writes.count == 1 && writes.first?.operation == .moveItem)
        #expect(writes.first?.destination?.contains("macros.json.corrupt-") == true)
        await harness.store.replaceMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        await harness.store.flush()
        #expect(harness.data(.macros) == nil)

        let relaunch = SettingsStoreHarness(reusing: harness)
        let again = await relaunch.store.load()
        #expect(again.notices == [.corruptFileUsingDefaults(.macros)])
        #expect(relaunch.spy.mutatingCalls.isEmpty)

        await relaunch.store.confirmDefaults(for: .macros)
        #expect(relaunch.object(.macros)?["macros"] == .array([]))
        await relaunch.store.confirmDefaults(for: .macros)  // no-op once confirmed
        let third = SettingsStoreHarness(reusing: relaunch)
        #expect(await third.store.load().notices.isEmpty)
    }

    @Test func everyKindOfParseFailureIsQuarantined() async {
        for text in ["", "[1,2]", #"{"writtenBy":"x"}"#, #"{"schemaVersion":-1}"#, #"{"schemaVersion":"1"}"#] {
            let harness = SettingsStoreHarness()
            harness.seed(.appModes, text)
            let state = await harness.store.load()
            #expect(state.notices == [.corruptFileUsingDefaults(.appModes)], "\(text)")
        }
        let unreadable = SettingsStoreHarness()
        unreadable.seed(.ruleOverrides, "{}")
        unreadable.spy.fail(.readData, at: unreadable.url(.ruleOverrides))
        #expect(await unreadable.store.load().notices == [.corruptFileUsingDefaults(.ruleOverrides)])
    }

    /// PLT-R1007: a newer file is used read-only for known fields and never rewritten.
    @Test func newerSchemaIsReadOnly() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, #"{"schemaVersion":2,"writtenBy":"9.0","settings":{"typingMethod":"vni","v2Only":1},"v2Section":{}}"#)
        let original = harness.data(.settings)
        let state = await harness.store.load()
        #expect(state.readOnlyFiles == [.settings])
        #expect(state.notices == [.newerSchemaReadOnly(.settings, schemaVersion: 2)])
        #expect(state.user.typingMethod == .set(.vni))
        await harness.store.updateSettings { $0.typingMethod = .set(.telex) }
        #expect(await harness.store.state.effective.typingMethod == .telex)
        await harness.advance(by: .seconds(10))
        await harness.store.flush()
        #expect(harness.data(.settings) == original)
        #expect(harness.spy.mutatingCalls.isEmpty)
    }
}

@Suite struct SettingsStoreSafeModeTests {
    private func crashLoop(_ harness: SettingsStoreHarness) {
        for index in 0..<3 { _ = LaunchGuard(store: harness.keyValues).beginLaunch(now: 1_800_000_000 + Double(index)) }
    }

    /// PLT-R1009: three launches that never survived start in safe mode without touching files.
    @Test func safeModeUsesDefaultsWithoutTouchingFiles() async throws {
        let setup = SettingsStoreHarness()
        seedRelease(SchemaFixtures.v1, in: setup)
        crashLoop(setup)
        let harness = SettingsStoreHarness(reusing: setup)
        #expect(harness.launchGuard.beginLaunch(now: 1_800_000_010))
        let before = harness.memory.nodes
        let state = await harness.store.load()
        #expect(state.safeMode)
        #expect(state.notices == [.safeMode(recentCrashes: 3)])
        #expect(state.user == UserSettings() && state.macros.isEmpty)
        await harness.store.updateSettings { $0.typingMethod = .set(.vni) }
        await harness.store.recordAppModes(AppModesDocument(globalMode: .english))
        await harness.advance(by: .seconds(10))
        await harness.store.flush()
        #expect(harness.spy.calls.isEmpty)
        #expect(harness.memory.nodes == before)
        await #expect(throws: SettingsImportError.unavailableInSafeMode) {
            try await harness.store.applyImport(
                ImportPreview(schemaVersion: 1, changedSettingKeys: [], appEntries: 0, ruleOverrides: 0, macros: nil, skippedFields: [], content: .null),
                choices: ImportChoices())
        }

        await harness.store.exitSafeMode()
        let normal = await harness.store.state
        #expect(!normal.safeMode && normal.notices.isEmpty)
        #expect(normal.macros.map(\.trigger) == ["vn", "@@"])
        #expect(harness.keyValues.integer(forKey: LaunchGuard.Key.recentCrashes) == 0)
    }

    @Test func resetFromSafeModeKeepsMacrosAndLeavesSafeMode() async throws {
        let setup = SettingsStoreHarness()
        seedRelease(SchemaFixtures.v1, in: setup)
        crashLoop(setup)
        let harness = SettingsStoreHarness(reusing: setup)
        _ = harness.launchGuard.beginLaunch(now: 1_800_000_010)
        _ = await harness.store.load()
        await harness.store.reset(.all(includeMacros: false))
        let state = await harness.store.state
        #expect(!state.safeMode)
        #expect(state.user.typingMethod == .unset)
        #expect(state.macros.count == 2)
        // Known keys are reset; the unknown key of a newer build survives the rewrite (PLT-R1002).
        #expect(harness.object(.settings)?["settings"] == .object(["futureSettingFromNewerBuild": .string("kept")]))
        #expect(!harness.launchGuard.isSafeModeActive)
    }

    @Test func exitSafeModeOutsideSafeModeOnlyResetsTheGuard() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let generation = await harness.store.state.generation
        await harness.store.exitSafeMode()
        #expect(await harness.store.state.generation == generation)
    }
}
