// SPDX-License-Identifier: LicenseRef-App-Pending
//
// App profiles (compat/scenarios/profiles/<id>.json, schema profile.schema.json next to them): the settings,
// macros and user rule overrides the app under test needs for some scenarios (QA-R11 macros `vn` and `@@`,
// restore hotkey, per-window rule; QA-R21 TestHost reproductions of shipped rules; privacy canary strategies;
// benchmark workload). A profile lists its scenarios, so the scenario schema stays unchanged. Every scenario runs
// on factory defaults plus its `method` plus its profile (AppConfiguration.swift); the harness writes them into the
// app's settings files and restarts the app (AppConfigurator.swift).

public import AppModel
public import Foundation

public struct AppProfile: Sendable, Hashable {
    public struct Macro: Sendable, Hashable {
        public var trigger: String
        public var expansion: String
        public var adaptCase: Bool
    }

    /// One user rule override (rule-overrides.json, 02-platform.md 5.8). `rule` is the user-override rule JSON;
    /// `bundleIds` may name `local.testhost`. `actionFromRule` copies `action` from a shipped rule of
    /// compat/rules.json, so a TestHost reproduction applies exactly the shipped behaviour (QA-R21).
    public struct RuleOverride: Sendable, Hashable {
        public var rule: JSONValue
        public var actionFromRule: String?
    }

    public var id: String
    public var summary: String
    public var scenarios: [String]
    /// Keys and values of the `settings` object of settings.json (contracts.md section 7), verbatim.
    public var settings: [String: JSONValue]
    public var macros: [Macro]
    public var ruleOverrides: [RuleOverride]
}

public struct AppProfileError: Error, Sendable, Hashable, CustomStringConvertible {
    public var file: String
    public var problems: [String]
    public var description: String { file + ": " + problems.joined(separator: "; ") }
}

public enum AppProfileLoader {
    public static let directoryName = "profiles"
    /// Files ending in this are schemas, not profiles.
    public static let schemaSuffix = ".schema.json"
    static let maximumFileBytes = 256 * 1024
    static let topLevelKeys: Set<String> = [
        "$schema", "id", "summary", "scenarios", "settings", "macros", "ruleOverrides",
    ]
    static let macroKeys: Set<String> = ["trigger", "expansion", "adaptCase"]
    static let overrideKeys: Set<String> = ["id", "summary", "match", "action", "actionFromRule"]
    /// The scenario's `method` sets this key; a profile must not.
    static let reservedSettings: Set<String> = ["typingMethod"]

    /// Profiles in `directory` sorted by file name; an absent directory has none.
    public static func load(directory: URL, fileSystem: any FileSystem) throws -> [AppProfile] {
        guard fileSystem.fileExists(at: directory) else { return [] }
        let files = try fileSystem.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(schemaSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let profiles = try files.map { file in
            try decode(fileSystem.readData(at: file, maxBytes: maximumFileBytes), fileName: file.lastPathComponent)
        }
        var owner: [String: String] = [:]
        for profile in profiles {
            for scenario in profile.scenarios {
                if let other = owner.updateValue(profile.id, forKey: scenario) {
                    throw AppProfileError(
                        file: profile.id + ".json", problems: ["scenario " + scenario + " is also in profile " + other])
                }
            }
        }
        return profiles
    }

    public static func decode(_ data: Data, fileName: String) throws(AppProfileError) -> AppProfile {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data), let object = raw.objectValue else {
            throw AppProfileError(file: fileName, problems: ["not a JSON object"])
        }
        var problems = unknown(object, topLevelKeys, path: "")
        let id = object["id"]?.stringValue ?? ""
        if !ScenarioValidator.isValidID(id) { problems.append("id must match ^[A-Za-z0-9_.-]+$") }
        if fileName != id + ".json" { problems.append("file name must be " + id + ".json") }
        let summary = object["summary"]?.stringValue ?? ""
        if summary.isEmpty { problems.append("summary is required") }
        let scenarios = strings(object["scenarios"], "scenarios", &problems)
        let settings = object["settings"]?.objectValue ?? [:]
        if object["settings"] != nil, object["settings"]?.objectValue == nil { problems.append("settings must be an object") }
        problems += settings.keys.filter(reservedSettings.contains).sorted().map { "settings." + $0 + " comes from the scenario's method" }
        let macros = macroList(object["macros"], &problems)
        let overrides = overrideList(object["ruleOverrides"], &problems)
        guard problems.isEmpty else { throw AppProfileError(file: fileName, problems: problems) }
        return AppProfile(
            id: id, summary: summary, scenarios: scenarios, settings: settings, macros: macros, ruleOverrides: overrides)
    }

    /// Problems a profile set has against the scenario files: unknown scenario ids, unknown shipped rules.
    public static func problems(_ profiles: [AppProfile], scenarioIDs: Set<String>, shippedRuleIDs: Set<String>)
        -> [String]
    {
        var problems: [String] = []
        for profile in profiles {
            problems += profile.scenarios.filter { !scenarioIDs.contains($0) }.map {
                profile.id + ": no scenario " + $0
            }
            problems += profile.ruleOverrides.compactMap(\.actionFromRule).filter { !shippedRuleIDs.contains($0) }.map {
                profile.id + ": no shipped rule " + $0
            }
        }
        return problems
    }

    private static func unknown(_ object: [String: JSONValue], _ allowed: Set<String>, path: String) -> [String] {
        object.keys.filter { !allowed.contains($0) }.sorted().map { "unknown key " + path + $0 }
    }

    private static func strings(_ value: JSONValue?, _ name: String, _ problems: inout [String]) -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) else {
            problems.append(name + " must be an array of strings")
            return []
        }
        return items.compactMap(\.stringValue)
    }

    private static func macroList(_ value: JSONValue?, _ problems: inout [String]) -> [AppProfile.Macro] {
        guard case .array(let items)? = value else { return [] }
        return items.enumerated().compactMap { index, item in
            let object = item.objectValue ?? [:]
            problems += unknown(object, macroKeys, path: "macros[\(index)].")
            guard let trigger = object["trigger"]?.stringValue, !trigger.isEmpty,
                let expansion = object["expansion"]?.stringValue
            else {
                problems.append("macros[\(index)] needs trigger and expansion")
                return nil
            }
            let adaptCase: Bool = if case .bool(let flag)? = object["adaptCase"] { flag } else { true }
            return AppProfile.Macro(trigger: trigger, expansion: expansion, adaptCase: adaptCase)
        }
    }

    private static func overrideList(_ value: JSONValue?, _ problems: inout [String]) -> [AppProfile.RuleOverride] {
        guard case .array(let items)? = value else { return [] }
        return items.enumerated().compactMap { index, item in
            let path = "ruleOverrides[\(index)]"
            guard var object = item.objectValue else {
                problems.append(path + " must be an object")
                return nil
            }
            problems += unknown(object, overrideKeys, path: path + ".")
            let source = object.removeValue(forKey: "actionFromRule")?.stringValue
            if (source == nil) == (object["action"] == nil) { problems.append(path + " needs exactly one of action, actionFromRule") }
            guard let id = object["id"]?.stringValue, id.hasPrefix("user."), ScenarioValidator.isValidID(id) else {
                problems.append(path + ".id must start with user.")
                return nil
            }
            if object["summary"]?.stringValue == nil || object["match"]?.objectValue == nil {
                problems.append(path + " needs summary and match")
            }
            return AppProfile.RuleOverride(rule: .object(object), actionFromRule: source)
        }
    }
}

extension Array where Element == AppProfile {
    /// The profile that lists `scenario`, if any.
    public func profile(for scenario: String) -> AppProfile? { first { $0.scenarios.contains(scenario) } }

    public func profile(named id: String) -> AppProfile? { first { $0.id == id } }
}
