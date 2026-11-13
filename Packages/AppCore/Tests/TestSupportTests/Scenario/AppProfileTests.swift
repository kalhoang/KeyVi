// SPDX-License-Identifier: LicenseRef-App-Pending
//
// App profiles and the configurator (QA-R11, QA-R21): profile decoding and validation, the repository profiles
// against their schema and the scenario files, the settings documents read back by the real SettingsStore, the
// user overrides resolved by the real RuleSet, and the configurator's quit, back up, write, launch, restore cycle
// over InMemoryFileSystem.

import AppModel
import CompatRules
import Foundation
import RealtimeSupport
import SettingsStore
import Testing

@testable import TestSupport

private let profilesDirectory = repositoryRoot.appendingPathComponent("compat/scenarios/profiles")

private func profileJSON(_ id: String, extra: String = "") -> String {
    #"{"id":""# + id + #"","summary":"s","scenarios":["a"]"# + extra + "}"
}

@Suite struct AppProfileDecodingTests {
    @Test func decodesEveryPart() throws {
        let json = """
            {"$schema":"profile.schema.json","id":"p","summary":"Profile","scenarios":["a","b"],
             "settings":{"restoreHotkey":{"type":"key","keyCode":53}},
             "macros":[{"trigger":"vn","expansion":"Việt Nam","adaptCase":false},{"trigger":"@@","expansion":"x"}],
             "ruleOverrides":[{"id":"user.p","summary":"s","match":{"bundleIds":["local.testhost"]},
                               "actionFromRule":"terminal.default"}]}
            """
        let profile = try AppProfileLoader.decode(Data(json.utf8), fileName: "p.json")
        #expect(profile.scenarios == ["a", "b"] && profile.settings.keys.sorted() == ["restoreHotkey"])
        #expect(profile.macros.map(\.adaptCase) == [false, true])
        #expect(profile.ruleOverrides.first?.actionFromRule == "terminal.default")
        #expect(profile.ruleOverrides.first?.rule["actionFromRule"] == nil)
    }

    @Test(arguments: [
        (profileJSON("p", extra: #","extra":1"#), "unknown key extra"),
        (profileJSON("q"), "file name must be q.json"),
        (#"{"id":"p","scenarios":[]}"#, "summary is required"),
        (
            profileJSON("p", extra: #","settings":{"typingMethod":"vni"}"#),
            "settings.typingMethod comes from the scenario's method"
        ),
        (profileJSON("p", extra: #","macros":[{"trigger":""}]"#), "macros[0] needs trigger and expansion"),
        (
            profileJSON("p", extra: #","ruleOverrides":[{"id":"x","summary":"s","match":{},"action":{}}]"#),
            "ruleOverrides[0].id must start with user."
        ),
        (
            profileJSON("p", extra: #","ruleOverrides":[{"id":"user.x","summary":"s","match":{}}]"#),
            "ruleOverrides[0] needs exactly one of action, actionFromRule"
        ),
        (#"{"id":"p","summary":"s","scenarios":"a"}"#, "scenarios must be an array of strings"),
        ("[]", "not a JSON object"),
    ])
    func rejects(json: String, problem: String) {
        #expect(throws: (any Error).self) { try AppProfileLoader.decode(Data(json.utf8), fileName: "p.json") }
        do {
            _ = try AppProfileLoader.decode(Data(json.utf8), fileName: "p.json")
        } catch {
            #expect(error.problems.contains(problem), "\(error.problems)")
        }
    }

    @Test func aScenarioBelongsToOneProfile() throws {
        let fileSystem = InMemoryFileSystem()
        let directory = URL(fileURLWithPath: "/p")
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        for id in ["one", "two"] {
            try fileSystem.writeAtomically(
                Data(profileJSON(id).utf8), to: directory.appendingPathComponent(id + ".json"),
                permissions: .ownerOnlyFile)
        }
        #expect(throws: AppProfileError(file: "two.json", problems: ["scenario a is also in profile one"])) {
            try AppProfileLoader.load(directory: directory, fileSystem: fileSystem)
        }
        #expect(try AppProfileLoader.load(directory: URL(fileURLWithPath: "/none"), fileSystem: fileSystem).isEmpty)
        let profiles = [try AppProfileLoader.decode(Data(profileJSON("one").utf8), fileName: "one.json")]
        #expect(AppProfileLoader.problems(profiles, scenarioIDs: ["b"], shippedRuleIDs: []) == ["one: no scenario a"])
        #expect(profiles.profile(for: "a")?.id == "one" && profiles.profile(named: "one") != nil)
        #expect(AppConfiguration.of(makeScenario(id: "a"), profiles: profiles).label == "telex + one")
    }
}

@Suite struct RepositoryProfileTests {
    @Test func profilesConformToTheirSchemaAndNameRealScenariosAndRules() throws {
        let schema = try JSONSchemaSubset(
            schemaData: Data(contentsOf: profilesDirectory.appendingPathComponent("profile.schema.json")))
        let files = try FileManager.default.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".schema.json") }
        #expect(files.count == 4)
        for file in files {
            let violations = schema.validate(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)))
            #expect(violations.isEmpty, "\(file.lastPathComponent): \(violations)")
        }
        let profiles = try repositoryProfiles()
        let scenarioIDs = Set(
            try ScenarioRunner.load(directory: repositoryRoot.appendingPathComponent("compat/scenarios")).map(\.id))
        let rules = try RuleScenarioCoverage.ruleScenarios(
            rulesData: Data(contentsOf: repositoryRoot.appendingPathComponent("compat/rules.json")))
        #expect(
            AppProfileLoader.problems(profiles, scenarioIDs: scenarioIDs, shippedRuleIDs: Set(rules.map(\.rule)))
                .isEmpty)
        #expect(profiles.profile(named: BenchWorkload.profileID)?.scenarios.isEmpty == true)
    }

    /// The real SettingsStore reads what the harness writes: every profile setting counts as set, the macros and
    /// overrides arrive, the method follows the scenario.
    @Test func settingsStoreReadsEveryProfile() async throws {
        let targets = try repositoryTargets()
        for profile in try repositoryProfiles() {
            for method in [Scenario.Method.telex, .vni] {
                let state = try await OracleSettings.load(
                    AppConfiguration(method: method, profile: profile), targets: targets)
                #expect(state.effective.typingMethod.rawValue == method.rawValue)
                #expect(Set(profile.settings.keys).isSubset(of: Set(state.user.explicitlySetKeys)), "\(profile.id)")
                #expect(state.macros.map(\.trigger) == profile.macros.map(\.trigger), "\(profile.id)")
                #expect(state.ruleOverrides.count == profile.ruleOverrides.count, "\(profile.id)")
                #expect(state.appModes.apps.isEmpty && state.appModes.globalMode == .vietnamese)
                #expect(state.notices.isEmpty && state.readOnlyFiles.isEmpty, "\(profile.id)")
            }
        }
        let qa = try #require(try repositoryProfiles().profile(named: "qa-r11"))
        let state = try await OracleSettings.load(AppConfiguration(method: .telex, profile: qa), targets: targets)
        #expect(state.effective.restoreHotkey == .key(.escape))
    }

    /// The overrides decode as user rules and win for exactly the TestHost fields they name (PLT-R522), with the
    /// strategy the scenario relies on.
    @Test func overridesResolveForTheirTestHostFields() throws {
        let targets = try repositoryTargets()
        let rulesData = try Data(contentsOf: repositoryRoot.appendingPathComponent("compat/rules.json"))
        let documents = AppSettingsDocuments(
            targets: targets, shippedActions: AppSettingsDocuments.shippedActions(rulesData: rulesData))
        let shipped = try RulesLoader.decode(rulesData)
        let testHost = try #require(targets.testHostBundleID)
        let expected: [String: [String: InjectionStrategy]] = [
            "qa-r11": ["testhost.second.textField": .passThrough],
            "privacy-canary": [
                "testhost.second.textView": .selectReplace, "testhost.second.textField": .axReplace,
                "testhost.second.plainField": .paste, "testhost.native.textView": .passThrough,
            ],
        ]
        for profile in try repositoryProfiles() {
            let raw = try profile.ruleOverrides.map { try documents.rule($0, profile: profile.id) }
            let (rules, rejected) = RulesLoader.decodeOverrides(raw)
            #expect(rejected.isEmpty, "\(profile.id): \(rejected)")
            let set = try RuleSet(document: shipped, overrides: rules, optedIn: [])
            for (field, strategy) in expected[profile.id] ?? [:] {
                let decision = set.resolve(context(testHost, identifier: field))
                #expect(decision.source == .user && decision.strategy == strategy, "\(profile.id) \(field)")
            }
            let main = set.resolve(context(testHost, identifier: "testhost.native.textField"))
            #expect(main.source != .user, "\(profile.id) must leave the main text field alone")
        }
    }

    private func context(_ bundle: BundleKey, identifier: String) -> MatchContext {
        MatchContext(
            bundle: bundle, appVersion: nil, macOS: LooseVersion("27.0")!, engine: .native, role: "AXTextField",
            identifier: identifier)
    }
}

@Suite struct AppSettingsDocumentsTests {
    private let targets = HarnessTargets(
        testHostBundleID: bundle("org.example.product.dev.testhost"), appUnderTestBundleID: nil,
        pagesDirectory: URL(fileURLWithPath: "/p"))

    @Test func resolvesTheAliasAndCopiesShippedActions() throws {
        let profile = try AppProfileLoader.decode(
            Data(
                #"{"id":"p","summary":"s","scenarios":[],"ruleOverrides":[{"id":"user.a","summary":"s","match":{"bundleIds":["local.testhost","com.example.Other"]},"actionFromRule":"r"}]}"#
                    .utf8), fileName: "p.json")
        let documents = AppSettingsDocuments(
            targets: targets, shippedActions: ["r": .object(["strategy": .string("paste")])])
        let rule = try documents.rule(profile.ruleOverrides[0], profile: "p")
        #expect(
            rule["match"]?["bundleIds"]
                == .array([.string("org.example.product.dev.testhost"), .string("com.example.Other")]))
        #expect(rule["action"]?["strategy"]?.stringValue == "paste")
        #expect(throws: AppConfigurationError.unknownShippedRule(profile: "p", rule: "r")) {
            try AppSettingsDocuments(targets: targets, shippedActions: [:]).rule(profile.ruleOverrides[0], profile: "p")
        }
        let unresolved = AppSettingsDocuments(
            targets: HarnessTargets(
                testHostBundleID: nil, appUnderTestBundleID: nil, pagesDirectory: URL(fileURLWithPath: "/p")),
            shippedActions: ["r": .object([:])])
        #expect(throws: AppConfigurationError.unresolvedTestHost(profile: "p")) {
            try unresolved.rule(profile.ruleOverrides[0], profile: "p")
        }
        #expect(AppConfigurationError.unresolvedTestHost(profile: "p").description.contains("local.testhost"))
        #expect(AppSettingsDocuments.shippedActions(rulesData: Data("[]".utf8)).isEmpty)
    }

    @Test func documentsKeepOnboardingAndUseStableMacroIDs() throws {
        let documents = AppSettingsDocuments(targets: targets, shippedActions: [:])
        let profile = AppProfile(
            id: "p", summary: "s", scenarios: [], settings: [:],
            macros: [.init(trigger: "vn", expansion: "Việt Nam", adaptCase: true)], ruleOverrides: [])
        let files = try documents.documents(
            for: AppConfiguration(method: .vni, profile: profile),
            onboarding: .object(["completedVersion": .string("1.0")]))
        let settings = try JSONDecoder().decode(JSONValue.self, from: try #require(files[.settings]))
        #expect(settings["settings"]?["typingMethod"]?.stringValue == "vni")
        #expect(settings["onboarding"]?["completedVersion"]?.stringValue == "1.0")
        #expect(settings["writtenBy"]?.stringValue == AppSettingsDocuments.writer)
        let macros = try JSONDecoder().decode(JSONValue.self, from: try #require(files[.macros]))
        guard case .array(let items)? = macros["macros"] else {
            Issue.record("macros must be an array")
            return
        }
        #expect(items.first?["id"]?.stringValue == "00000000-0000-4000-8000-000000000001")
        #expect(AppSettingsDocuments.macroID(11) == "00000000-0000-4000-8000-000000000012")
        #expect(Set(files.keys) == Set(SettingsFile.allCases))
    }
}

@Suite struct SettingsFileAppConfiguratorTests {
    private let location = StorageLocation(directory: URL(fileURLWithPath: "/support/App"))
    private let backup = URL(fileURLWithPath: "/out/backup")

    private func configurator(
        _ fileSystem: InMemoryFileSystem, control: FakeAppControl, hooks: (any AppHookClient)?, clock: ManualClock
    ) -> SettingsFileAppConfigurator {
        SettingsFileAppConfigurator(
            location: location, backupDirectory: backup, fileSystem: fileSystem, control: control,
            documents: AppSettingsDocuments(
                targets: HarnessTargets(
                    testHostBundleID: nil, appUnderTestBundleID: nil, pagesDirectory: URL(fileURLWithPath: "/p")),
                shippedActions: [:]),
            hooks: hooks, clock: clock, sleeper: ClockSleeper(clock: clock))
    }

    @Test func applyBacksUpOnceWritesAndRestartsThenRestorePutsEverythingBack() async throws {
        let fileSystem = InMemoryFileSystem()
        try fileSystem.createDirectory(at: location.directory, permissions: .ownerOnlyDirectory)
        let original = Data(
            #"{"schemaVersion":1,"settings":{"typingMethod":"telex"},"onboarding":{"completedVersion":"0.1"}}"#.utf8)
        try fileSystem.writeAtomically(original, to: location.url(for: .settings), permissions: .ownerOnlyFile)
        let control = FakeAppControl()
        control.setRunning(true)
        let clock = ManualClock()
        let start = clock.now().nanoseconds
        let subject = configurator(fileSystem, control: control, hooks: nil, clock: clock)
        try await subject.apply(AppConfiguration(method: .vni))
        try await subject.apply(AppConfiguration(method: .vni))  // unchanged: nothing happens
        #expect(control.events.all == ["quit", "launch"])
        #expect(clock.now().nanoseconds - start == SettingsFileAppConfigurator.settleNanoseconds)
        let written = try JSONDecoder().decode(
            JSONValue.self, from: fileSystem.readData(at: location.url(for: .settings), maxBytes: 1 << 20))
        #expect(written["settings"]?["typingMethod"]?.stringValue == "vni")
        #expect(written["onboarding"]?["completedVersion"]?.stringValue == "0.1")
        for file in SettingsFile.allCases {
            #expect(try fileSystem.attributes(at: location.url(for: file)).permissions == .ownerOnlyFile)
        }
        try await subject.apply(.factory)
        #expect(try fileSystem.readData(at: subject.backupURL(.settings), maxBytes: 1 << 20) == original)
        try await subject.restore()
        #expect(try fileSystem.readData(at: location.url(for: .settings), maxBytes: 1 << 20) == original)
        #expect(!fileSystem.fileExists(at: location.url(for: .macros)))  // did not exist before the run
        #expect(control.events.all == ["quit", "launch", "quit", "launch", "quit", "launch"])
        try await subject.restore()  // nothing backed up any more
        #expect(control.events.all.count == 6)
    }

    @Test func readinessUsesTheHooksAndFallsBackWhenTheyAreSilent() async throws {
        let clock = ManualClock()
        let origin = clock.now().nanoseconds
        let starting = FakeHookClient(state: snapshot(.starting))
        let ready = FakeHookClient(state: snapshot(.ready))
        let control = FakeAppControl()
        try await configurator(InMemoryFileSystem(), control: control, hooks: ready, clock: clock).apply(.factory)
        #expect(ready.commands.all == ["state"] && clock.now().nanoseconds == origin)
        await #expect(throws: AppHookError.timeout(command: "state")) {
            try await configurator(InMemoryFileSystem(), control: control, hooks: starting, clock: clock).apply(
                .factory)
        }
        let silent = FakeHookClient { _ in throw AppHookError.timeout(command: "state") }
        let start = clock.now().nanoseconds
        try await configurator(InMemoryFileSystem(), control: control, hooks: silent, clock: clock).apply(.factory)
        #expect(clock.now().nanoseconds - start == SettingsFileAppConfigurator.settleNanoseconds)
    }
}
