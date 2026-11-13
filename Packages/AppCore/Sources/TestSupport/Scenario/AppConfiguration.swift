// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the app under test is configured with for one scenario: factory defaults, the scenario's typing method
// and its profile (AppProfiles.swift). `AppSettingsDocuments` renders that as the four settings files of
// ADR 0307 (contracts.md section 7), exactly as the app reads them; SettingsStore round-trip tests prove it.

public import AppModel
public import Foundation
public import SettingsStore

public struct AppConfiguration: Sendable, Hashable {
    public var method: Scenario.Method
    public var profile: AppProfile?

    public init(method: Scenario.Method, profile: AppProfile? = nil) {
        self.method = method
        self.profile = profile
    }

    /// Factory defaults (Telex, no profile): the soak and the start of every run.
    public static let factory = AppConfiguration(method: .telex)

    /// The configuration a scenario needs.
    public static func of(_ scenario: Scenario, profiles: [AppProfile]) -> AppConfiguration {
        AppConfiguration(method: scenario.method, profile: profiles.profile(for: scenario.id))
    }

    /// Short label for plans and logs: `vni`, `telex + qa-r11`.
    public var label: String { method.rawValue + (profile.map { " + " + $0.id } ?? "") }
}

public enum AppConfigurationError: Error, Sendable, Hashable, CustomStringConvertible {
    case unresolvedTestHost(profile: String)
    case unknownShippedRule(profile: String, rule: String)

    public var description: String {
        switch self {
        case .unresolvedTestHost(let profile):
            "profile " + profile + " names local.testhost, which is unresolved (scripts/brand.env missing)"
        case .unknownShippedRule(let profile, let rule): "profile " + profile + " copies unknown rule " + rule
        }
    }
}

/// Renders a configuration as settings files. Pure; the configurator writes the result.
public struct AppSettingsDocuments: Sendable {
    /// `writtenBy` of every file the harness writes.
    public static let writer = "compat-harness"
    /// `createdAt` of the overrides: a fixed instant, so the files are reproducible.
    public static let overrideCreatedAt = "2026-01-01T00:00:00Z"

    public var targets: HarnessTargets
    /// `action` of every shipped rule by id (compat/rules.json), for `actionFromRule`.
    public var shippedActions: [String: JSONValue]

    public init(targets: HarnessTargets, shippedActions: [String: JSONValue]) {
        self.targets = targets
        self.shippedActions = shippedActions
    }

    /// `action` of every rule of a rules document (compat/rules.json).
    public static func shippedActions(rulesData: Data) -> [String: JSONValue] {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: rulesData),
            case .array(let rules)? = document["rules"]
        else { return [:] }
        var actions: [String: JSONValue] = [:]
        for rule in rules {
            if let id = rule["id"]?.stringValue, let action = rule["action"] { actions[id] = action }
        }
        return actions
    }

    /// The four documents. `onboarding` is the `onboarding` object of the settings file found on the machine,
    /// kept so the app does not show onboarding again (PRD-R42).
    public func documents(for configuration: AppConfiguration, onboarding: JSONValue?) throws -> [SettingsFile: Data] {
        let profile = configuration.profile
        var settings = profile?.settings ?? [:]
        settings["typingMethod"] = .string(configuration.method.rawValue)
        var settingsDocument = envelope(["settings": .object(settings)])
        if let onboarding { settingsDocument["onboarding"] = onboarding }
        let macros = (profile?.macros ?? []).enumerated().map { index, macro in
            JSONValue.object([
                "id": .string(Self.macroID(index)), "trigger": .string(macro.trigger),
                "expansion": .string(macro.expansion), "adaptCase": .bool(macro.adaptCase), "enabled": .bool(true),
            ])
        }
        let overrides = try (profile?.ruleOverrides ?? []).map { override in
            JSONValue.object([
                "createdAt": .string(Self.overrideCreatedAt), "rule": try rule(override, profile: profile?.id ?? ""),
            ])
        }
        return try [
            .settings: Self.encode(settingsDocument),
            .macros: Self.encode(envelope(["macros": .array(macros)])),
            .ruleOverrides: Self.encode(envelope(["overrides": .array(overrides)])),
            .appModes: Self.encode(
                envelope(["globalMode": .string(TypingMode.vietnamese.rawValue), "apps": .array([])])),
        ]
    }

    /// The user rule with `local.testhost` resolved and `actionFromRule` replaced by the shipped action.
    func rule(_ override: AppProfile.RuleOverride, profile: String) throws -> JSONValue {
        guard var object = override.rule.objectValue else { return override.rule }
        if let source = override.actionFromRule {
            guard let action = shippedActions[source] else {
                throw AppConfigurationError.unknownShippedRule(profile: profile, rule: source)
            }
            object["action"] = action
        }
        if var match = object["match"]?.objectValue, case .array(let bundles)? = match["bundleIds"] {
            match["bundleIds"] = .array(
                try bundles.map { bundle in
                    guard bundle.stringValue == HarnessTargets.testHostAlias else { return bundle }
                    guard let testHost = targets.testHostBundleID else {
                        throw AppConfigurationError.unresolvedTestHost(profile: profile)
                    }
                    return .string(testHost.rawValue)
                })
            object["match"] = .object(match)
        }
        return .object(object)
    }

    private func envelope(_ payload: [String: JSONValue]) -> [String: JSONValue] {
        payload.merging(["schemaVersion": .number(1), "writtenBy": .string(Self.writer)]) { current, _ in current }
    }

    /// Stable macro ids (`00000000-0000-4000-8000-000000000001`, ...), so rewriting a profile changes nothing.
    static func macroID(_ index: Int) -> String {
        let digits = String(index + 1)
        return "00000000-0000-4000-8000-" + String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    }

    static func encode(_ object: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }
}
