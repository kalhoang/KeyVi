// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loads and validates compat/scenarios/*.json (PLT-R530). Strict like the schema: unknown keys are errors
// (`additionalProperties: false`), the file name is the scenario id (CompatRules' linter resolves a rule's
// `test.scenario` to `compat/scenarios/<id>.json`), and every semantic rule the schema cannot express is
// checked by `ScenarioValidator`.

public import AppModel
internal import CompatRules
internal import Diagnostics
public import Foundation

public struct ScenarioLoadError: Error, Sendable, Hashable, CustomStringConvertible {
    public var file: String
    public var problems: [String]
    public var description: String { file + ": " + problems.joined(separator: "; ") }
}

public struct ScenarioLoader: Sendable {
    /// Scenario files are small; anything larger is not a scenario.
    public static let maximumFileBytes = 256 * 1024

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = LocalFileSystem()) { self.fileSystem = fileSystem }

    /// `*.json` files of `directory` sorted by name. Other files (README.md) are ignored.
    public func scenarioFiles(in directory: URL) throws -> [URL] {
        try fileSystem.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func load(directory: URL) throws -> [Scenario] {
        var scenarios: [Scenario] = []
        var seen: Set<String> = []
        for file in try scenarioFiles(in: directory) {
            let scenario = try load(file: file)
            guard seen.insert(scenario.id).inserted else {
                throw ScenarioLoadError(file: file.lastPathComponent, problems: ["duplicate id " + scenario.id])
            }
            scenarios.append(scenario)
        }
        return scenarios
    }

    public func load(file: URL) throws -> Scenario {
        let name = file.lastPathComponent
        let data = try fileSystem.readData(at: file, maxBytes: Self.maximumFileBytes)
        return try Self.decode(data, fileName: name)
    }

    /// Decodes one scenario document and validates it. `fileName` must be `<id>.json`.
    public static func decode(_ data: Data, fileName: String) throws(ScenarioLoadError) -> Scenario {
        let decoder = JSONDecoder()
        let raw: JSONValue
        let scenario: Scenario
        do {
            raw = try decoder.decode(JSONValue.self, from: data)
            scenario = try decoder.decode(Scenario.self, from: data)
        } catch {
            throw ScenarioLoadError(
                file: fileName, problems: ["not a valid scenario document: " + Self.describe(error)])
        }
        var problems = ScenarioValidator.unknownKeys(in: raw)
        problems += ScenarioValidator.problems(in: scenario)
        if fileName != scenario.id + ".json" {
            problems.append("file name must be " + scenario.id + ".json")
        }
        guard problems.isEmpty else { throw ScenarioLoadError(file: fileName, problems: problems) }
        return scenario
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing key " + key.stringValue
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
            DecodingError.dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".") + " " + context.debugDescription
        default: "unreadable JSON"
        }
    }
}

/// Semantic checks over a decoded scenario, mirroring compat/schema/scenario.schema.json plus the rules the
/// schema cannot state (values required by an action, wait bounds, webdriver needs a page).
public enum ScenarioValidator {
    public static let topLevelKeys: Set<String> = [
        "$schema", "id", "targetBundleId", "setup", "keys", "timing", "method", "layout", "expect", "readback",
        "repeat",
    ]
    public static let setupKeys: Set<String> = ["action", "value"]
    public static let expectKeys: Set<String> = [
        "text", "paused", "holderBundleId", "firstKeyAfterReleaseComposed", "noPlaceholderResidue",
    ]
    public static let repeatKeys: Set<String> = ["words", "seed", "timing", "prefix"]
    /// Longest `wait` step accepted, in milliseconds.
    public static let maximumWaitMilliseconds = 60_000
    /// Most words a `repeat` block may type (schema `maximum`): ten times the PLT-R422 gate.
    public static let maximumRepeatWords = 10_000
    /// Setup actions the Swift model accepts that compat/schema/scenario.schema.json does not list yet.
    /// `ScenarioFilesTests` keeps the difference to exactly this set, and no scenario file may use these actions
    /// until the schema lists them. Empty since W3-A added `testHook` to the schema (ADR 0502, "Integration hooks").
    public static let pendingSchemaActions: Set<Scenario.SetupStep.Action> = []

    public static func problems(in scenario: Scenario) -> [String] {
        var problems: [String] = []
        if !isValidID(scenario.id) { problems.append("id must match ^[A-Za-z0-9_.-]+$") }
        do throws(KeyScriptError) {
            _ = try ScenarioKeys.strokes(scenario.keys)
        } catch {
            problems.append(keyProblem(error))
        }
        let expect = scenario.expect
        if expect.text == nil, expect.paused == nil, expect.holderBundleId == nil,
            expect.firstKeyAfterReleaseComposed == nil, expect.noPlaceholderResidue == nil
        {
            problems.append("expect needs at least one expectation")
        }
        if let repetition = scenario.repetition { problems += repetitionProblems(repetition, in: scenario) }
        for (index, step) in scenario.setup.enumerated() {
            if let problem = problem(in: step, keyCount: scenario.keys.count) {
                problems.append("setup[\(index)] " + problem)
            }
        }
        if scenario.readback == .webdriver, !scenario.setup.contains(where: { $0.action == .openURL }) {
            problems.append("webdriver readback needs an openURL step")
        }
        return problems
    }

    /// Keys the schema forbids (`additionalProperties: false` at every level).
    public static func unknownKeys(in raw: JSONValue) -> [String] {
        guard let object = raw.objectValue else { return ["document must be an object"] }
        var problems = object.keys.filter { !topLevelKeys.contains($0) }.sorted().map { "unknown key " + $0 }
        if case .array(let steps)? = object["setup"] {
            for (index, step) in steps.enumerated() {
                let extra = (step.objectValue?.keys).map { $0.filter { !setupKeys.contains($0) } } ?? []
                problems += extra.sorted().map { "unknown key setup[\(index)]." + $0 }
            }
        }
        let expectExtra = (object["expect"]?.objectValue?.keys).map { $0.filter { !expectKeys.contains($0) } } ?? []
        problems += expectExtra.sorted().map { "unknown key expect." + $0 }
        let repeatExtra = (object["repeat"]?.objectValue?.keys).map { $0.filter { !repeatKeys.contains($0) } } ?? []
        problems += repeatExtra.sorted().map { "unknown key repeat." + $0 }
        return problems
    }

    /// PLT-R422 gate shape: Telex words (the soak corpus), a readback that checks every word without a person,
    /// a bounded word count and a valid, non-empty prefix.
    static func repetitionProblems(_ repetition: Scenario.Repetition, in scenario: Scenario) -> [String] {
        var problems: [String] = []
        if !(1...maximumRepeatWords).contains(repetition.words) {
            problems.append("repeat.words must be 1 to \(maximumRepeatWords)")
        }
        if scenario.method != .telex { problems.append("repeat needs method telex (Telex soak corpus words)") }
        if !PlaceholderGate.automaticReadbacks.contains(scenario.readback.rawValue) {
            problems.append("repeat needs an ax or webdriver readback")
        }
        do throws(KeyScriptError) {
            _ = try ScenarioKeys.strokes(repetition.prefix)
        } catch {
            problems.append(keyProblem(error, field: "repeat.prefix"))
        }
        return problems
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty
            && id.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                    || byte == 0x2E || byte == 0x2D || byte == 0x5F
            }
    }

    static func keyProblem(_ error: KeyScriptError, field: String = "keys") -> String {
        switch error {
        case .emptyScript: field + " must not be empty"
        case .unknownKey(let index, let name): field + "[\(index)] '" + name + "' is not a physical key name"
        }
    }

    private static func problem(in step: Scenario.SetupStep, keyCount: Int) -> String? {
        let value = step.value ?? ""
        switch step.action {
        case .launch:
            return step.value.map { BundleKey(rawValue: $0) == nil ? "launch value must be a bundle id" : nil } ?? nil
        case .openURL, .seedHistory, .focusField:
            return value.isEmpty ? step.action.rawValue + " needs a value" : nil
        case .selectInputSource:
            return InputSourceID(rawValue: value) == nil ? "selectInputSource needs an input source id" : nil
        case .setSecureInput:
            return value == "on" || value == "off" ? nil : "setSecureInput value must be on or off"
        case .wait:
            guard let milliseconds = Int(value), (1...maximumWaitMilliseconds).contains(milliseconds) else {
                return "wait value must be 1 to \(maximumWaitMilliseconds) milliseconds"
            }
            return nil
        case .testHook:
            guard let hook = ScenarioHookStep.parse(value) else {
                let names = AppTestHook.allCases.map(\.rawValue).joined(separator: ", ")
                return "testHook value must be one of " + names + ", optionally @<key count>"
            }
            if let after = hook.afterKeys, after > keyCount { return "testHook @\(after) is past the end of keys" }
            return nil
        }
    }
}
