// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Small builders for rules, documents and match contexts. Bundle identifiers appear only in test fixtures
// (PLT-R501).

import AppModel
import Foundation

@testable import CompatRules

func ruleID(_ raw: String) -> RuleID {
    guard let id = RuleID(rawValue: raw) else { preconditionFailure("bad rule id in test") }
    return id
}

func bundleKey(_ raw: String) -> BundleKey {
    guard let key = BundleKey(rawValue: raw) else { preconditionFailure("bad bundle key in test") }
    return key
}

func version(_ raw: String) -> LooseVersion {
    guard let value = LooseVersion(raw) else { preconditionFailure("bad version in test") }
    return value
}

/// 2026-11-13, the date the seeded data was written.
let referenceDay = Date(timeIntervalSince1970: Double(ISODay("2026-11-13")!.ordinal) * 86_400)

func day(_ iso: String) -> Date { Date(timeIntervalSince1970: Double(ISODay(iso)!.ordinal) * 86_400) }

enum Build {
    static let defaults = RuleDefaults(
        strategy: .backspaceReplace,
        params: StrategyParams(
            unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0,
            inlineCompletion: InlineCompletionMode.none),
        fallback: [.passThrough], defaultMode: .inherit, requireTextFocus: .byEngine, verifyReentry: .whenReadable)

    static func provenance(
        tested date: String = "2026-11-01", result: TestedEntry.Result = .pass, reviewBy: String = "2027-05-01"
    ) -> RuleProvenance {
        .shipped(
            Provenance(
                reason: "Symptom and cause in one sentence.", evidence: [Evidence(type: "scenario", ref: "compat/x")],
                tested: [TestedEntry(app: "App", appVersion: "1.0", macOS: "27.1", date: date, result: result)],
                addedIn: "1.0.0", reviewBy: reviewBy))
    }

    static func rule(
        _ id: String, match: RuleMatch, action: RuleAction = RuleAction(strategy: .backspaceReplace),
        automation: RuleTest.Automation = .automated, provenance: RuleProvenance? = Build.provenance()
    ) -> Rule {
        Rule(
            id: ruleID(id), summary: "Summary of " + id, match: match, action: action, provenance: provenance,
            test: RuleTest(scenario: id, automation: automation))
    }

    static func userRule(_ id: String, match: RuleMatch, action: RuleAction = RuleAction(strategy: .selectReplace))
        -> Rule
    {
        Rule(
            id: ruleID(id), summary: "Set by the user", match: match, action: action,
            provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-13")))
    }

    static func document(
        _ rules: [Rule], groups: [String: [BundleKey]] = [:], conflicting: [BundleKey] = [],
        hints: [SecureInputHint] = [], defaults: RuleDefaults = Build.defaults
    ) -> RulesDocument {
        RulesDocument(
            schemaVersion: 1, rulesetVersion: "2026.11.0", defaults: defaults, bundleGroups: groups,
            conflictingInputApps: conflicting, secureInputHints: hints, rules: rules)
    }

    static func ruleSet(
        _ rules: [Rule], overrides: [Rule] = [], optedIn: Set<RuleID> = [], groups: [String: [BundleKey]] = [:]
    ) throws -> RuleSet {
        try RuleSet(document: document(rules, groups: groups), overrides: overrides, optedIn: optedIn)
    }

    static func context(
        bundle: String? = "com.example.editor", engine: EngineFingerprint = .native, appVersion: String? = "1.0",
        macOS: String = "27.1", category: String? = nil, role: String? = nil, subrole: String? = nil,
        identifier: String? = nil, domClasses: [String] = [], ancestorRoles: [String] = [], editable: Bool? = nil,
        url: String? = nil, title: String? = nil
    ) -> MatchContext {
        MatchContext(
            bundle: bundle.map(bundleKey), appVersion: appVersion.map(version), macOS: version(macOS), engine: engine,
            appCategory: category, role: role, subrole: subrole, identifier: identifier, domClasses: domClasses,
            ancestorRoles: ancestorRoles, editable: editable, documentURL: url, windowTitle: title)
    }

    static func seededDocument() throws -> RulesDocument { try RulesLoader.decode(RepoFiles.data(RepoFiles.rules)) }
    static func seededMatrix() throws -> MatrixDocument { try MatrixLoader.decode(RepoFiles.data(RepoFiles.matrix)) }
    static func seededRuleSet() throws -> RuleSet {
        try RuleSet(document: seededDocument(), overrides: [], optedIn: [])
    }
}
