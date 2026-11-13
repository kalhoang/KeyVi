// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R530: scenario documents decode strictly, validate, and load from a directory in file-name order.

import AppModel
import Foundation
import Testing

@testable import TestSupport

@Suite struct ScenarioLoadingTests {
    private func decode(_ json: String, file: String) throws(ScenarioLoadError) -> Scenario {
        try ScenarioLoader.decode(Data(json.utf8), fileName: file)
    }

    @Test func decodesAMinimalDocument() throws {
        let scenario = try decode(scenarioJSON(id: "a.b"), file: "a.b.json")
        #expect(scenario.id == "a.b")
        #expect(scenario.targetBundleId == bundle("com.example.Editor"))
        #expect(scenario.keys == ["d", "d", "i"])
        #expect(scenario.timing == .burst)
        #expect(scenario.layout == nil)
        #expect(scenario.expect.text == "đi")
    }

    @Test func roundTripsThroughJSONEncoder() throws {
        let scenario = makeScenario(
            setup: [.init(action: .launch), .init(action: .wait, value: "200")],
            expect: .init(
                text: "x", paused: true, holderBundleId: bundle("com.example.Holder"),
                firstKeyAfterReleaseComposed: false))
        let data = try JSONEncoder().encode(scenario)
        #expect(try ScenarioLoader.decode(data, fileName: "sample.scenario.json") == scenario)
    }

    @Test(arguments: [
        (scenarioJSON(id: "s", extra: #","layout":"com.apple.keylayout.ABC","extra":1"#), "unknown key extra"),
        (
            scenarioJSON(id: "s").replacingOccurrences(of: #"{"text":"đi"}"#, with: #"{"text":"x","colour":"red"}"#),
            "unknown key expect.colour"
        ),
    ])
    func rejectsUnknownKeysLikeTheSchema(json: String, problem: String) {
        // JSONDecoder ignores unknown keys; the schema says additionalProperties false.
        #expect(throws: ScenarioLoadError.self) { try decode(json, file: "s.json") }
        do {
            _ = try decode(json, file: "s.json")
        } catch {
            #expect(error.problems.contains(problem))
        }
    }

    @Test func rejectsUnknownSetupKeys() {
        let json = scenarioJSON(id: "s", setup: #"[{"action":"launch","delay":3}]"#)
        do {
            _ = try decode(json, file: "s.json")
            Issue.record("expected a load error")
        } catch {
            #expect(error.problems == ["unknown key setup[0].delay"])
        }
    }

    @Test func fileNameMustBeTheID() {
        // CompatRules resolves a rule's test.scenario to compat/scenarios/<id>.json.
        do {
            _ = try decode(scenarioJSON(id: "right.name"), file: "wrong.json")
            Issue.record("expected a load error")
        } catch {
            #expect(error.file == "wrong.json")
            #expect(error.problems == ["file name must be right.name.json"])
        }
    }

    @Test func reportsMalformedDocuments() {
        #expect(throws: ScenarioLoadError.self) { try decode("{", file: "x.json") }
        #expect(throws: ScenarioLoadError.self) { try decode("[]", file: "x.json") }
        do {
            _ = try decode(#"{"id":"x"}"#, file: "x.json")
        } catch {
            #expect(error.problems.first?.contains("missing key") == true)
            #expect(error.description.hasPrefix("x.json: "))
        }
        do {
            _ = try decode(scenarioJSON(id: "x", target: "not a bundle"), file: "x.json")
        } catch {
            #expect(error.problems.first?.contains("invalid bundle key") == true)
        }
        do {
            _ = try decode(scenarioJSON(id: "x").replacingOccurrences(of: #""burst""#, with: "5"), file: "x.json")
        } catch {
            #expect(error.problems.first?.contains("timing") == true)
        }
    }

    @Test func loadsADirectorySortedAndIgnoresOtherFiles() throws {
        let fileSystem = try makeCheckout(scenarios: [
            "b.json": scenarioJSON(id: "b"), "a.json": scenarioJSON(id: "a"), "README.md": "not a scenario",
        ])
        let loaded = try ScenarioLoader(fileSystem: fileSystem).load(
            directory: URL(fileURLWithPath: "/repo/compat/scenarios"))
        #expect(loaded.map(\.id) == ["a", "b"])
    }

    @Test func loadStopsAtTheFirstInvalidFileAndNamesIt() throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a"), "b.json": scenarioJSON(id: "c")])
        do {
            _ = try ScenarioLoader(fileSystem: fileSystem).load(
                directory: URL(fileURLWithPath: "/repo/compat/scenarios"))
            Issue.record("expected a load error")
        } catch let error as ScenarioLoadError {
            #expect(error.file == "b.json")
        }
    }

    @Test func duplicateIDsAreRejected() throws {
        // Two files cannot carry the same id once file names are checked, so test the guard directly.
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        let loader = ScenarioLoader(fileSystem: fileSystem)
        let file = URL(fileURLWithPath: "/repo/compat/scenarios/a.json")
        try fileSystem.copyItem(at: file, to: URL(fileURLWithPath: "/repo/compat/scenarios/a.copy.json"))
        #expect(throws: ScenarioLoadError.self) {
            _ = try loader.load(directory: URL(fileURLWithPath: "/repo/compat/scenarios"))
        }
        #expect(try loader.load(file: file).id == "a")
    }

    @Test func runnerLoadUsesTheLocalFileSystem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w2e1-load-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(scenarioJSON(id: "local.one").utf8).write(to: directory.appendingPathComponent("local.one.json"))
        #expect(try ScenarioRunner.load(directory: directory).map(\.id) == ["local.one"])
    }

    @Test func oversizedFilesAreRefused() throws {
        let fileSystem = try makeCheckout(scenarios: [:])
        let big = URL(fileURLWithPath: "/repo/compat/scenarios/big.json")
        try fileSystem.writeAtomically(
            Data(count: ScenarioLoader.maximumFileBytes + 1), to: big, permissions: .ownerOnlyFile)
        #expect(throws: FileSystemError.self) { _ = try ScenarioLoader(fileSystem: fileSystem).load(file: big) }
    }
}

@Suite struct ScenarioValidatorTests {
    @Test func validScenarioHasNoProblems() {
        #expect(ScenarioValidator.problems(in: makeScenario()) == [])
    }

    @Test func idMustBeFileSafe() {
        #expect(ScenarioValidator.problems(in: makeScenario(id: "has space")) == ["id must match ^[A-Za-z0-9_.-]+$"])
        #expect(ScenarioValidator.problems(in: makeScenario(id: "")).contains("id must match ^[A-Za-z0-9_.-]+$"))
    }

    @Test func keysMustBePhysicalKeyNames() {
        #expect(ScenarioValidator.problems(in: makeScenario(keys: [])) == ["keys must not be empty"])
        #expect(
            ScenarioValidator.problems(in: makeScenario(keys: ["a", "đ"])) == ["keys[1] 'đ' is not a physical key name"]
        )
    }

    @Test func expectationMustNotBeEmpty() {
        #expect(
            ScenarioValidator.problems(in: makeScenario(expect: Scenario.Expectation()))
                == ["expect needs at least one expectation"])
    }

    @Test(arguments: [
        (Scenario.SetupStep(action: .launch, value: "not a bundle"), "setup[0] launch value must be a bundle id"),
        (Scenario.SetupStep(action: .openURL), "setup[0] openURL needs a value"),
        (Scenario.SetupStep(action: .seedHistory, value: ""), "setup[0] seedHistory needs a value"),
        (Scenario.SetupStep(action: .focusField), "setup[0] focusField needs a value"),
        (
            Scenario.SetupStep(action: .selectInputSource, value: "sha256:x"),
            "setup[0] selectInputSource needs an input source id"
        ),
        (Scenario.SetupStep(action: .setSecureInput, value: "yes"), "setup[0] setSecureInput value must be on or off"),
        (Scenario.SetupStep(action: .wait, value: "0"), "setup[0] wait value must be 1 to 60000 milliseconds"),
        (Scenario.SetupStep(action: .wait, value: "soon"), "setup[0] wait value must be 1 to 60000 milliseconds"),
    ])
    func setupValuesAreChecked(step: Scenario.SetupStep, problem: String) {
        #expect(ScenarioValidator.problems(in: makeScenario(setup: [step])) == [problem])
    }

    @Test func validSetupStepsPass() {
        let steps: [Scenario.SetupStep] = [
            .init(action: .launch), .init(action: .launch, value: "com.example.Other"),
            .init(action: .openURL, value: "{pages}/fields.html"), .init(action: .seedHistory, value: "file:///x"),
            .init(action: .focusField, value: "testhost.native.textField"),
            .init(action: .selectInputSource, value: "com.apple.keylayout.ABC"),
            .init(action: .setSecureInput, value: "off"),
            .init(action: .wait, value: "60000"),
        ]
        #expect(ScenarioValidator.problems(in: makeScenario(setup: steps)) == [])
    }

    @Test func webdriverReadbackNeedsAPage() {
        #expect(
            ScenarioValidator.problems(in: makeScenario(readback: .webdriver)) == [
                "webdriver readback needs an openURL step"
            ])
    }

    @Test func unknownKeysOnNonObjects() {
        #expect(ScenarioValidator.unknownKeys(in: .array([])) == ["document must be an object"])
    }
}
