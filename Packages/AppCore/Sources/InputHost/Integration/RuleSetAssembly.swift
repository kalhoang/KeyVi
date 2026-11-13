// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shipped rules + `rule-overrides.json` + opted-in rule IDs -> the compiled `RuleSet` the focus tracker resolves
// with (PLT-R503, PLT-R522, PLT-R540). Pure; called on main at launch and whenever overrides or opt-ins change.
// Workstream W2-A.

public import AppModel
public import CompatRules
public import SettingsStore

/// The inputs of a rule set that come from settings. When they are unchanged a settings change does not
/// recompile rules or re-resolve focus.
public struct RuleSetInputs: Sendable, Hashable {
    public var overrides: [StoredRuleOverride]
    public var optedIn: Set<RuleID>

    public init(settings: SettingsState) {
        overrides = settings.ruleOverrides
        optedIn = settings.effective.optedInRules
    }
}

public struct RuleSetAssembly: Sendable {
    public var ruleSet: RuleSet
    /// User overrides that failed validation, one by one; the rest still apply (PLT-R540).
    public var rejectedOverrides: [RejectedOverride]
    /// Set when the shipped file was invalid (embedded defaults in use, PLT-R503) or the overrides as a whole
    /// could not be compiled (they are then dropped and the shipped rules apply).
    public var error: RulesValidationError?

    /// Never throws: a set that cannot be compiled falls back to the shipped rules without overrides, then to
    /// the embedded minimal ruleset (PLT-R503).
    public static func build(rules: RulesLoadResult, inputs: RuleSetInputs) -> RuleSetAssembly {
        let decoded = RulesLoader.decodeOverrides(inputs.overrides.map(\.rule))
        do {
            let ruleSet = try RuleSet(document: rules.document, overrides: decoded.rules, optedIn: inputs.optedIn)
            return RuleSetAssembly(ruleSet: ruleSet, rejectedOverrides: decoded.rejected, error: rules.error)
        } catch {
            return RuleSetAssembly(
                ruleSet: shippedOnly(rules.document, optedIn: inputs.optedIn), rejectedOverrides: decoded.rejected,
                error: error)
        }
    }

    /// True when a health event belongs in the log (PLT-R503, PLT-R540).
    public var needsHealthEvent: Bool { error != nil || !rejectedOverrides.isEmpty }

    private static func shippedOnly(_ document: RulesDocument, optedIn: Set<RuleID>) -> RuleSet {
        if let ruleSet = try? RuleSet(document: document, overrides: [], optedIn: optedIn) { return ruleSet }
        // The embedded ruleset is compiled into the app and validated by its own tests.
        return try! RuleSet(document: EmbeddedRules.minimal, overrides: [], optedIn: [])
    }
}
