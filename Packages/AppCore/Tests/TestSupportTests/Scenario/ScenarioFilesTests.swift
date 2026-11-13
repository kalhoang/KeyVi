// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W2-E1 acceptance over the repository's compat/scenarios: every file decodes and validates against
// compat/schema/scenario.schema.json, the 02-platform.md 13.2 minimum set and the 5.6 example rules are present,
// `compat-harness run --dry-run` loads them all and plans without touching live services, and every rule in
// compat/rules.json has a scenario file (PLT-R505, PLT-R530, QA-R21).

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

private let scenariosDirectory = repositoryRoot.appendingPathComponent("compat/scenarios")

private func scenarioFiles() throws -> [URL] {
    try ScenarioLoader().scenarioFiles(in: scenariosDirectory)
}

@Suite struct ScenarioFilesTests {
    @Test func everyFileDecodesAndValidates() throws {
        let scenarios = try ScenarioRunner.load(directory: scenariosDirectory)
        #expect(scenarios.count == (try scenarioFiles()).count)
        #expect(scenarios.count >= 40)
    }

    /// Schema conformance against the schema file itself, so the Swift types and the schema cannot drift.
    @Test func everyFileConformsToTheScenarioSchema() throws {
        let schema = try JSONSchemaSubset(
            schemaData: Data(contentsOf: repositoryRoot.appendingPathComponent("compat/schema/scenario.schema.json")))
        for file in try scenarioFiles() {
            let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            let violations = schema.validate(document)
            #expect(violations.isEmpty, "\(file.lastPathComponent): \(violations)")
        }
    }

    /// 02-platform.md 13.2 minimum automated scenario set.
    @Test func minimumSetOfSection13_2IsPresent() throws {
        let ids = Set(try scenarioFiles().map { $0.deletingPathExtension().lastPathComponent })
        let required = [
            "textedit.telex.basic", "textedit.vni.basic", "notes.telex.basic", "browser.webkit.addressBar",
            "safari.page.textarea", "browser.chromium.addressBar", "chrome.page.textarea", "browser.gecko.urlBar",
            "terminal.default", "terminal.iterm2", "terminal.ghostty", "editor.vscodeFamily", "launcher.spotlight",
            "testhost.password.noTransform", "testhost.native.telex", "testhost.native.vni", "testhost.layout.abc",
            "testhost.layout.qwertz", "testhost.layout.azerty", "testhost.layout.dvorak",
            "testhost.inputSource.japanese",
            "testhost.secureInput.pause", "testhost.secureInput.release", "terminal.iterm2.secureKeyboardEntry",
            "terminal.iterm2.secureKeyboardEntryOff", "testhost.tapTimeout.recovery",
            "testhost.failOpen.permissionRevoked",
            "testhost.web.inlineAutocomplete", "testhost.web.editModeTransition", "testhost.web.composer",
        ]
        #expect(Set(required).subtracting(ids).isEmpty, "missing: \(Set(required).subtracting(ids).sorted())")
    }

    /// Every rule id of the 02-platform.md 5.6 examples has its scenario (test.scenario equals the rule id there).
    @Test func specExampleRulesHaveScenarios() throws {
        let ids = Set(try scenarioFiles().map { $0.deletingPathExtension().lastPathComponent })
        let examples = [
            "browser.chromium.addressBar", "web.googleSheets.cellEditor", "terminal.default", "design.shortcutHeavy",
            "remote.passThrough",
        ]
        #expect(Set(examples).subtracting(ids).isEmpty)
    }

    /// Scenario semantics the schema cannot state: what the 13.2 scenarios assert.
    @Test func keyScenariosAssertWhatSection13_2Asks() throws {
        let byID = Dictionary(
            uniqueKeysWithValues: try ScenarioRunner.load(directory: scenariosDirectory).map { ($0.id, $0) })
        #expect(byID["testhost.password.noTransform"]?.expect.text == "duyeetj")  // PLT-R387: untransformed
        #expect(byID["testhost.inputSource.japanese"]?.expect.paused == true)  // PLT-R371
        let pause = try #require(byID["testhost.secureInput.pause"])
        #expect(pause.expect.paused == true && pause.expect.holderBundleId?.rawValue == HarnessTargets.testHostAlias)
        #expect(byID["testhost.secureInput.release"]?.expect.firstKeyAfterReleaseComposed == true)  // PLT-R398B
        #expect(byID["terminal.iterm2.secureKeyboardEntry"]?.expect.holderBundleId?.rawValue == "com.googlecode.iterm2")
        #expect(byID["testhost.native.vni"]?.method == .vni && byID["testhost.native.telex"]?.method == .telex)
        #expect(Set(byID.values.map(\.timing)) == [.normal, .fast, .burst])
        #expect(byID["chrome.page.textarea"]?.readback == .webdriver)
        #expect(byID["terminal.default"]?.readback == .terminalCapture)
    }

    /// TestHost scenarios use the alias and real TestHost field identifiers.
    @Test func testHostScenariosUseKnownFields() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("TestHost/Sources/TestHostFields.swift"), encoding: .utf8)
        for scenario in try ScenarioRunner.load(directory: scenariosDirectory) where scenario.id.hasPrefix("testhost.")
        {
            #expect(scenario.targetBundleId.rawValue == HarnessTargets.testHostAlias, "\(scenario.id)")
            for step in scenario.setup where step.action == .focusField {
                #expect(source.contains("\"" + (step.value ?? "") + "\""), "\(scenario.id): \(step.value ?? "")")
            }
        }
    }

    /// `{pages}` references point at real local pages; no scenario names a remote page.
    @Test func pageReferencesExist() throws {
        for scenario in try ScenarioRunner.load(directory: scenariosDirectory) {
            for step in scenario.setup where step.action == .openURL {
                let value = try #require(step.value)
                if value.hasPrefix(HarnessTargets.pagesPlaceholder + "/") {
                    let page = value.dropFirst(HarnessTargets.pagesPlaceholder.count + 1).split(separator: "#")[0]
                    let path = repositoryRoot.appendingPathComponent(HarnessTargets.pagesPath).appendingPathComponent(
                        String(page))
                    #expect(FileManager.default.fileExists(atPath: path.path), "\(scenario.id): \(page)")
                } else {
                    Issue.record("\(scenario.id): openURL must use a local page: \(value)")
                }
            }
            for step in scenario.setup where step.action == .seedHistory {
                #expect(step.value?.contains(".localhost:") == true, "\(scenario.id): seed history on loopback only")
            }
        }
    }

    /// Brand rule: scenario files never spell the product's bundle IDs (they use `local.testhost`).
    @Test func scenarioFilesAreBrandNeutral() throws {
        let brand = BrandEnvironment.parse(
            try String(contentsOf: repositoryRoot.appendingPathComponent("scripts/brand.env"), encoding: .utf8))
        let forbidden = ["APP_BUNDLE_ID_RELEASE", "APP_BUNDLE_ID_DEV", "APP_SITE_HOST"].compactMap { brand[$0] }
        #expect(forbidden.count == 3)
        for file in try scenarioFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for value in forbidden { #expect(!text.contains(value), "\(file.lastPathComponent)") }
        }
    }

    /// Acceptance: `compat-harness run --dry-run` loads all scenarios and prints the plan without posting.
    @Test func dryRunOverTheRepositoryPlansEveryScenarioWithoutPosting() async throws {
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock)
        let console = BufferedConsole()
        var options = try HarnessCommandLine.parse(["run", "--dry-run", "--scenarios", "compat/scenarios"])
        options.repository = repositoryRoot.path
        options.rules = "compat/rules.json"
        let environment = HarnessEnvironment(fileSystem: LocalFileSystem(), console: console, clock: clock, live: live)
        let exit = await Harness(options: options, environment: environment).execute()
        let text = console.output.joined(separator: "\n")
        #expect(exit == .success, "\(console.errors)")
        for file in try scenarioFiles() {
            #expect(text.contains("- " + file.deletingPathExtension().lastPathComponent + "\n"))
        }
        #expect(!text.contains("UNRESOLVED"))
        #expect(live.calls.all.isEmpty)
        #expect(live.sink.records.isEmpty)
    }

    @Test func soakAndBenchDryRunsUseTheRepositoryDefaults() async throws {
        for arguments in [["soak", "--dry-run", "--keystrokes", "1000000"], ["bench", "--dry-run", "--runs", "5"]] {
            let live = RecordingLiveServices(clock: ManualClock())
            let console = BufferedConsole()
            var options = try HarnessCommandLine.parse(arguments)
            options.repository = repositoryRoot.path
            let environment = HarnessEnvironment(
                fileSystem: LocalFileSystem(), console: console, clock: ManualClock(), live: live)
            #expect(
                await Harness(options: options, environment: environment).execute() == .success, "\(console.errors)")
            #expect(live.calls.all.isEmpty)
        }
    }

    /// PLT-R505 / QA-R21: every rule in compat/rules.json references an existing scenario. Lists the gaps for
    /// the integrator (also `compat-harness coverage`). Passes trivially while the rules file does not exist.
    @Test func everyShippedRuleHasAScenarioFile() throws {
        let rules = repositoryRoot.appendingPathComponent("compat/rules.json")
        guard FileManager.default.fileExists(atPath: rules.path) else { return }
        let ids = Set(try scenarioFiles().map { $0.deletingPathExtension().lastPathComponent })
        let gaps = try RuleScenarioCoverage.gaps(rulesData: Data(contentsOf: rules), scenarioIDs: ids)
        #expect(gaps.isEmpty, "rules without a scenario file: \(gaps.map(\.description))")
    }
}
