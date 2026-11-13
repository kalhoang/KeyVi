// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

private func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

private func override(_ id: String, at seconds: Double = 1_800_000_000.4) -> StoredRuleOverride {
    StoredRuleOverride(
        createdAt: Date(timeIntervalSince1970: seconds),
        rule: .object(["id": .string(id), "strategy": .string("paste")]))
}

@Suite struct SettingsStoreDebounceTests {
    /// PLT-R1003: atomic write 1 s after the first change, changes in between coalesce, 0600 in a 0700 folder.
    @Test func writesOneSecondAfterTheFirstChange() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.typingMethod = .set(.vni) }
        await harness.advance(by: .milliseconds(500))
        await harness.store.updateSettings { $0.tonePlacement = .set(.modern) }
        await harness.advance(by: .milliseconds(499))
        #expect(harness.data(.settings) == nil)
        await harness.advance(by: .milliseconds(1))
        let written = try #require(harness.object(.settings))
        #expect(written["schemaVersion"] == .number(1))
        #expect(written["writtenBy"] == .string("0.1.0"))
        #expect(written["settings"]?["typingMethod"] == .string("vni"))
        #expect(written["settings"]?["tonePlacement"] == .string("modern"))
        #expect(harness.memory.nodes[harness.url(.settings).path]?.permissions == .ownerOnlyFile)
        #expect(harness.memory.nodes[SettingsStoreHarness.directory.path]?.permissions == .ownerOnlyDirectory)
        let writes = harness.spy.mutatingCalls.filter { $0.operation == .writeAtomically }.map(\.path)
        #expect(writes.filter { $0 == harness.url(.settings).path }.count == 1)
    }

    /// PLT-R392: app-mode memory is written after 5 s; an explicit rule shortens a pending write to 1 s.
    @Test func appModesUseFiveSecondsAndRulesOneSecond() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.recordAppModes(
            AppModesDocument(globalMode: .english, apps: [AppModeEntry(bundle: bundle("a.a"), mode: .english)]))
        await harness.advance(by: .seconds(4))
        #expect(harness.data(.appModes) == nil)
        await harness.advance(by: .seconds(1))
        #expect(harness.object(.appModes)?["globalMode"] == .string("en"))

        await harness.store.recordAppModes(
            AppModesDocument(globalMode: .vietnamese, apps: [AppModeEntry(bundle: bundle("a.a"), mode: .vietnamese)]))
        await harness.advance(by: .milliseconds(100))
        await harness.store.setAppRule(.ignore, for: bundle("b.b"))
        await harness.advance(by: .seconds(1))
        let apps = arrayItems(harness.object(.appModes)?["apps"])
        #expect(apps.map { $0["bundle"] } == [.string("b.b"), .string("a.a")])
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func recordAppModesNeverRevertsARulePRDR21() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.setAppRule(.alwaysEnglish, for: bundle("term.app"))
        // The ax thread's copy predates the rule.
        await harness.store.recordAppModes(
            AppModesDocument(globalMode: .english, apps: [AppModeEntry(bundle: bundle("term.app"), mode: .vietnamese)]))
        let entry = await harness.store.state.appModes.apps.first
        #expect(entry == AppModeEntry(bundle: bundle("term.app"), rule: .alwaysEnglish, mode: .vietnamese))
        let generation = await harness.store.state.generation
        await harness.store.setAppRule(.alwaysEnglish, for: bundle("term.app"))
        await harness.store.recordAppModes(await harness.store.state.appModes)
        #expect(await harness.store.state.generation == generation)
    }

    @Test func flushWritesEverythingPendingNow() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.replaceMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        await harness.store.addRuleOverride(override("user.a"))
        await harness.store.recordAppModes(AppModesDocument(globalMode: .english))
        await harness.store.flush()
        #expect(
            harness.object(.macros) != nil && harness.object(.ruleOverrides) != nil && harness.object(.appModes) != nil)
        #expect(harness.scheduler.pendingCount == 0)
        await harness.advance(by: .seconds(10))
        let writes = harness.spy.mutatingCalls.filter { $0.operation == .writeAtomically }.map(\.path)
        #expect(writes.filter { !$0.contains("/backups/") }.count == 3)
    }

    @Test func nothingIsWrittenBeforeLoad() async {
        let harness = SettingsStoreHarness()
        await harness.store.updateSettings { $0.typingMethod = .set(.vni) }
        await harness.advance(by: .seconds(2))
        await harness.store.flush()
        #expect(harness.spy.mutatingCalls.isEmpty)
    }

    @Test func unchangedUpdatesPublishNothing() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let count = harness.recorder.count
        await harness.store.updateSettings { _ in }
        await harness.store.replaceMacros([])
        await harness.store.removeRuleOverride(id: RuleID(rawValue: "user.none")!)
        await harness.store.setAppRule(nil, for: bundle("x.y"))
        #expect(harness.recorder.count == count)
        #expect(harness.scheduler.pendingCount == 0)
    }

    /// PLT-R1008: every change is published with a new generation, on the store's queue.
    @Test func changesArePublishedLive() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.englishRestore = .set(false) }
        let last = harness.recorder.last
        #expect(last?.effective.englishRestore == false)
        #expect(harness.recorder.all.map(\.generation) == [1, 2])
    }
}

@Suite struct SettingsStorePersistenceTests {
    @Test func unknownKeysSurviveARewriteThroughTheStorePLTR1002() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, SchemaFixtures.v1.settings)
        harness.seed(.appModes, SchemaFixtures.v1.appModes)
        harness.seed(.macros, SchemaFixtures.v1.macros)
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.soundOnSwitch = .set(true) }
        await harness.store.setAppRule(.alwaysEnglish, for: bundle("com.example.Terminal"))
        var macros = await harness.store.state.macros
        macros[0].expansion = "Việt Nam!"
        await harness.store.replaceMacros(macros)
        await harness.store.flush()
        let settings = try #require(harness.object(.settings))
        #expect(settings["futureKeyFromNewerBuild"] == .object(["kept": .bool(true)]))
        #expect(settings["settings"]?["futureSettingFromNewerBuild"] == .string("kept"))
        #expect(settings["settings"]?["toggleHotkey"]?["futureHotkeyField"] == .number(7))
        #expect(settings["onboarding"]?["futureStep"] == .number(3))
        let apps = arrayItems(harness.object(.appModes)?["apps"])
        #expect(apps.first?["futureEntryKey"] == .string("x"))
        #expect(apps.first?["rule"] == .string("alwaysEnglish"))
        #expect(harness.object(.appModes)?["futureTopLevel"] == .number(1))
        #expect(arrayItems(harness.object(.macros)?["macros"]).first?["futureMacroKey"] == .string("x"))
        // Reload: the same state.
        let next = SettingsStoreHarness(reusing: harness)
        let reloaded = await next.store.load()
        #expect(reloaded.user == (await harness.store.state.user))
        #expect(reloaded.macros == (await harness.store.state.macros))
    }

    /// PRD-R23: per-app memory survives a restart.
    @Test func appMemorySurvivesARestart() async {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        let document = AppModesDocument(
            globalMode: .english,
            apps: [
                AppModeEntry(bundle: bundle("a.a"), mode: .english),
                AppModeEntry(bundle: bundle("b.b"), mode: .vietnamese),
            ])
        await harness.store.recordAppModes(document)
        await harness.store.flush()
        let next = SettingsStoreHarness(reusing: harness)
        #expect(await next.store.load().appModes == document)
    }

    /// Rotation backups (PLT-R1006, section 10 acceptance): every complete write leaves its bytes as the newest
    /// backup, also the first write of a fresh install; newest five kept.
    @Test func everyWriteLeavesItsBytesAsTheNewestBackupAndPrunesToFive() async throws {
        var harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.typingMethod = .set(.vni) }
        await harness.store.flush()
        let firstBackup = try #require(harness.paths.first { $0.hasPrefix("backups/settings.json.v1.") })
        #expect(harness.memory.nodes["/Settings/" + firstBackup]?.data == harness.data(.settings))
        #expect(harness.memory.nodes["/Settings/" + firstBackup]?.permissions == .ownerOnlyFile)
        for launch in 0..<7 {
            harness.wallClock.advance(by: 3_600)
            harness = SettingsStoreHarness(reusing: harness)
            _ = await harness.store.load()
            await harness.store.updateSettings { $0.soundOnSwitch = .set(launch % 2 == 0) }
            await harness.store.flush()
            await harness.store.updateSettings { $0.clickIconToToggle = .set(launch % 2 == 0) }
            await harness.store.flush()
        }
        let backups = harness.paths.filter { $0.hasPrefix("backups/settings.json.v1.") }
        #expect(backups.count == 5)
        let storage = DocumentStorage(
            location: harness.location, fileSystem: harness.memory, wallClock: harness.wallClock)
        let dates = storage.backups(of: .settings).map(\.date)
        #expect(dates == dates.sorted(by: >))
        #expect(dates.first == harness.wallClock.now())
        let newest = try #require(storage.backups(of: .settings).first)
        #expect(harness.memory.nodes[newest.url.path]?.data == harness.data(.settings))
    }

    /// PLT-R1005: rotation backups of the current schema never push out the pre-migration copies of an older
    /// one (the newest five are kept per schema version).
    @Test func rotationBackupsDoNotPrunePreMigrationBackups() async throws {
        var harness = SettingsStoreHarness(migrations: TestMigrations.chain)
        harness.seed(.settings, SchemaFixtures.v0Settings)
        _ = await harness.store.load()
        #expect(harness.paths.filter { $0.hasPrefix("backups/settings.json.v0.") }.count == 1)
        for launch in 0..<7 {
            harness.wallClock.advance(by: 3_600)
            harness = SettingsStoreHarness(reusing: harness, migrations: TestMigrations.chain)
            _ = await harness.store.load()
            await harness.store.updateSettings { $0.soundOnSwitch = .set(launch % 2 == 0) }
            await harness.store.flush()
        }
        #expect(harness.paths.filter { $0.hasPrefix("backups/settings.json.v0.") }.count == 1)
        #expect(harness.paths.filter { $0.hasPrefix("backups/settings.json.v1.") }.count == 5)
    }

    @Test func sameSecondBackupsGetDistinctNames() throws {
        let harness = SettingsStoreHarness()
        let storage = DocumentStorage(
            location: harness.location, fileSystem: harness.memory, wallClock: harness.wallClock)
        for index in 0..<3 {
            try storage.writeBackup(Data("{\"schemaVersion\":1,\"n\":\(index)}".utf8), of: .macros, schemaVersion: 1)
        }
        let backups = storage.backups(of: .macros)
        #expect(backups.map(\.sequence) == [2, 1, 0])
        #expect(DocumentStorage.parseBackupName(URL(fileURLWithPath: "/x/macros.json.vX.1.json"), of: .macros) == nil)
        #expect(DocumentStorage.parseBackupName(URL(fileURLWithPath: "/x/macros.json.v1.bad.json"), of: .macros) == nil)
        #expect(DocumentStorage.parseBackupName(URL(fileURLWithPath: "/x/macros.json.v1"), of: .macros) == nil)
    }

    @Test func aFailedWriteRaisesANoticeAndRecoversOnTheNextWrite() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        harness.spy.fail(.writeAtomically, at: harness.url(.macros))
        await harness.store.replaceMacros([StoredMacro(trigger: "vn", expansion: "x")])
        await harness.advance(by: .seconds(1))
        #expect(await harness.store.state.notices == [.writeFailed(.macros, errno: EIO)])
        harness.spy.clearFailures()
        await harness.store.replaceMacros([StoredMacro(trigger: "vn", expansion: "y")])
        await harness.advance(by: .seconds(1))
        #expect(await harness.store.state.notices.isEmpty)
        #expect(arrayItems(harness.object(.macros)?["macros"]).first?["expansion"] == .string("y"))
    }

    @Test func overridesAreAddedReplacedAndRemovedPLTR541() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.addRuleOverride(override("user.a"))
        await harness.store.addRuleOverride(override("user.b"))
        await harness.store.addRuleOverride(override("user.a", at: 1_800_000_100))
        await harness.store.addRuleOverride(
            StoredRuleOverride(createdAt: .now, rule: .object(["id": .string("shipped.x")])))
        var state = await harness.store.state
        #expect(state.ruleOverrides.map { $0.rule["id"] } == [.string("user.a"), .string("user.b")])
        #expect(state.ruleOverrides[0].createdAt == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(state.ruleOverrides[1].createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        await harness.store.removeRuleOverride(id: RuleID(rawValue: "user.a")!)
        await harness.store.flush()
        state = await harness.store.state
        #expect(state.ruleOverrides.count == 1)
        let next = SettingsStoreHarness(reusing: harness)
        #expect(await next.store.load().ruleOverrides == state.ruleOverrides)
        #expect(
            arrayItems(harness.object(.ruleOverrides)?["overrides"]).first?["createdAt"]
                == .string("2027-01-15T08:00:00Z"))
    }
}

@Suite struct SettingsStoreResetTests {
    private func loadedFixture() async -> SettingsStoreHarness {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, SchemaFixtures.v1.settings)
        harness.seed(.appModes, SchemaFixtures.v1.appModes)
        harness.seed(.ruleOverrides, SchemaFixtures.v1.ruleOverrides)
        harness.seed(.macros, SchemaFixtures.v1.macros)
        _ = await harness.store.load()
        await harness.store.updateSettings {
            $0.soundOnSwitch = .set(true)
            $0.automaticallyInstallUpdates = .set(false)
            $0.macrosEnabled = .set(false)
            $0.firstSeenAppMode = .set(.en)
        }
        return harness
    }

    @Test func generalPaneResetsOnlyGeneralKeys() async {
        let harness = await loadedFixture()
        await harness.store.reset(.general)
        let user = await harness.store.state.user
        #expect(user.toggleHotkey == .unset && user.soundOnSwitch == .unset && user.layoutBinding == .unset)
        #expect(user.typingMethod == .set(.vni) && user.firstSeenAppMode == .set(.en))
        #expect(user.automaticallyInstallUpdates == .set(false))
    }

    @Test func typingPaneResetsTypingKeysAndLists() async {
        let harness = await loadedFixture()
        await harness.store.reset(.typing)
        let user = await harness.store.state.user
        #expect(user.typingMethod == .unset && user.restoreHotkey == .unset)
        #expect(user.keepAsTyped.isEmpty && user.keepVietnamese.isEmpty)
        #expect(user.soundOnSwitch == .set(true))
    }

    @Test func appsPaneResetsRulesMemoryAndOverrides() async {
        let harness = await loadedFixture()
        await harness.store.reset(.apps)
        let state = await harness.store.state
        #expect(state.appModes.apps.isEmpty && state.appModes.globalMode == .english)
        #expect(state.ruleOverrides.isEmpty && state.user.optedInRules.isEmpty)
        #expect(state.user.firstSeenAppMode == .unset && state.user.typingMethod == .set(.vni))
        #expect(state.macros.count == 2)
    }

    /// PRD-R26: the Macros pane resets D9 and D10 to "unset" and keeps the list unless the box is ticked; only
    /// the files it rewrites are backed up first (PLT-R1006 "never wipe").
    @Test func macrosPaneResetUnsetsTheSwitchesAndKeepsTheListUnlessAsked_PRDR26() async throws {
        let harness = await loadedFixture()
        await harness.store.updateSettings { $0.macrosInEnglishMode = .set(true) }
        await harness.store.reset(.macros(includeList: false))
        var state = await harness.store.state
        #expect(state.user.macrosEnabled == .unset && state.user.macrosInEnglishMode == .unset)
        #expect(state.user.soundOnSwitch == .set(true) && state.user.typingMethod == .set(.vni))
        #expect(state.macros.count == 2)
        #expect(harness.object(.settings)?["settings"]?["macrosEnabled"] == nil)
        #expect(harness.paths.contains { $0.hasPrefix("backups/settings.json.v1.") })
        #expect(!harness.paths.contains { $0.hasPrefix("backups/macros.json") })

        await harness.store.reset(.macros(includeList: true))
        state = await harness.store.state
        #expect(state.macros.isEmpty)
        #expect(harness.object(.macros)?["macros"] == .array([]))
        #expect(harness.paths.contains { $0.hasPrefix("backups/macros.json.v1.") })
    }

    /// PLT-R1006: an edit earlier in the session already backed up the on-disk list once; deleting the list
    /// from the Macros pane still keeps the list as it was just before the reset recoverable.
    @Test func macrosListResetBacksUpTheListAsItIsNow_PLTR1006() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.replaceMacros([StoredMacro(trigger: "vn", expansion: "Việt Nam")])
        await harness.store.flush()
        await harness.store.replaceMacros([
            StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "dc", expansion: "được"),
        ])
        await harness.store.flush()
        await harness.store.reset(.macros(includeList: true))
        let backups = harness.paths.filter { $0.hasPrefix("backups/macros.json") }.compactMap { path in
            harness.memory.nodes[SettingsStoreHarness.directory.path + "/" + path]?.data.map {
                String(decoding: $0, as: UTF8.self)
            }
        }
        #expect(backups.contains { $0.contains("\"dc\"") && $0.contains("\"vn\"") })
        #expect(await harness.store.state.macros.isEmpty)
    }

    /// PRD-R26: global reset keeps macros unless the separate box is ticked; files are backed up first.
    @Test func globalResetKeepsMacrosUnlessAskedAndBacksUpFirst() async throws {
        let harness = await loadedFixture()
        await harness.store.reset(.all(includeMacros: false))
        var state = await harness.store.state
        #expect(state.user.explicitlySetKeys.isEmpty)
        #expect(state.user.onboarding.completedVersion == "0.1.0")
        #expect(state.macros.count == 2)
        #expect(harness.paths.contains { $0.hasPrefix("backups/settings.json.v1.") })
        #expect(harness.paths.contains { $0.hasPrefix("backups/app-modes.json.v1.") })
        #expect(!harness.paths.contains { $0.hasPrefix("backups/macros.json") })
        #expect(harness.object(.settings)?["settings"]?["soundOnSwitch"] == nil)
        await harness.store.reset(.all(includeMacros: true))
        state = await harness.store.state
        #expect(state.macros.isEmpty)
        #expect(harness.object(.macros)?["macros"] == .array([]))
        #expect(harness.paths.contains { $0.hasPrefix("backups/macros.json.v1.") })
    }

    /// PRD-R6: a value from a newer build of the same schema survives ordinary writes; resetting its pane is
    /// the user's explicit choice and removes it, while other panes' values stay.
    @Test func undecodableValuesSurviveWritesUntilTheirPaneIsReset() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(
            .settings,
            #"{"schemaVersion":1,"settings":{"typingMethod":"dvorak","updateChannel":"nightly","soundOnSwitch":"loud"}}"#
        )
        _ = await harness.store.load()
        await harness.store.updateSettings { $0.clickIconToToggle = .set(true) }
        await harness.store.flush()
        var settings = harness.object(.settings)?["settings"]
        #expect(settings?["typingMethod"] == .string("dvorak"))
        #expect(settings?["updateChannel"] == .string("nightly"))
        await harness.store.reset(.typing)
        settings = harness.object(.settings)?["settings"]
        #expect(settings?["typingMethod"] == nil)
        #expect(settings?["updateChannel"] == .string("nightly"))
        #expect(settings?["soundOnSwitch"] == .string("loud"))
        await harness.store.reset(.all(includeMacros: false))
        settings = harness.object(.settings)?["settings"]
        #expect(settings?["updateChannel"] == nil && settings?["soundOnSwitch"] == nil)
    }

    @Test func resetReplacesAReadOnlyFileAfterBackingItUp() async throws {
        let harness = SettingsStoreHarness()
        harness.seed(.settings, #"{"schemaVersion":2,"writtenBy":"9.0","settings":{"typingMethod":"vni"}}"#)
        _ = await harness.store.load()
        await harness.store.reset(.typing)
        let state = await harness.store.state
        #expect(state.readOnlyFiles.isEmpty && state.notices.isEmpty)
        #expect(harness.object(.settings)?["schemaVersion"] == .number(1))
        #expect(harness.paths.contains { $0.hasPrefix("backups/settings.json.v2.") })
    }
}

@Suite struct SettingsStoreConcurrencyTests {
    /// Many callers at once: every change lands, writes stay serialized (TSan target).
    @Test func concurrentUpdatesAllLand() async throws {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let key = "w\(index)"
                    await harness.store.updateSettings { $0.keepAsTyped.insert(key) }
                    if index % 10 == 0 { await harness.store.flush() }
                }
                group.addTask { _ = await harness.store.state }
            }
        }
        await harness.store.flush()
        #expect(await harness.store.state.user.keepAsTyped.count == 200)
        let next = SettingsStoreHarness(reusing: harness)
        #expect(await next.store.load().user.keepAsTyped.count == 200)
    }

    @Test func productionInitUsesTheDispatchScheduler() async {
        let queue = DispatchQueue(label: "settings-default-scheduler")
        let store = SettingsStore(
            location: StorageLocation(directory: URL(fileURLWithPath: "/Settings")), fileSystem: InMemoryFileSystem(),
            wallClock: FixedWallClock(), writtenBy: "0.1.0", queue: queue,
            launchGuard: LaunchGuard(store: InMemoryKeyValueStore()), onChange: { _ in })
        #expect(await store.scheduler is DispatchDebounceScheduler)
        #expect(await store.load().generation == 1)
    }
}
