// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One "this app" user override per app (PLT-R540). The Apps pane's compatibility mode (PRD-R36) and the status
// line's "type here anyway" (02-platform.md section 6, custom text views) both write a bundle-only user override.
// Two of them for one app tie (same specificity, same source), only the smaller id applies because rule actions
// are never merged (PLT-R520), and every focus change records a tie (PLT-R521). So each writer edits the app's
// existing override instead of adding a second one:
// - `user.compat.<bundle>`: the strategy and pacing are the compatibility mode the user chose, optionally with
//   `requireTextFocus: never`;
// - `user.textfocus.<bundle>`: only "type here anyway", with the strategy the app resolved to when it was chosen.
// At most one of the two exists per app; the id says whether the strategy is a choice the Apps pane shows.

public import AppModel
public import Foundation
import InputHost
public import SettingsStore

/// What a choice does to `rule-overrides.json` (PLT-R540), in order: the new rule is added before the one it
/// replaces is removed, so the app is never without its override in between.
public enum CompatibilityModeCommand: Sendable, Hashable {
    case add(StoredRuleOverride)
    case remove(RuleID)
}

/// The app's current bundle-only user override as written by the shell.
struct AppOverrideState {
    let compatID: RuleID
    let textFocusID: RuleID
    let compat: StoredRuleOverride?
    let hasTextFocusRule: Bool
    /// "Type here anyway" is in force, in either rule.
    let typeAnyway: Bool

    /// The defaults' strategy (`defaults.strategy` of compat-rules.json). A "type here anyway" that outlives a
    /// compatibility mode keeps it: actions do not merge across rules (PLT-R520), so the strategy the app had
    /// before the mode cannot be recovered from the rule alone.
    static let automaticStrategy = InjectionStrategy.backspaceReplace
    static let never = JSONValue.string(RequireTextFocus.never.rawValue)

    init(bundle: BundleKey, overrides: [StoredRuleOverride]) {
        compatID = CompatibilityModeChoice.ruleID(for: bundle)
        textFocusID = TextFocusOverride.ruleID(for: bundle)
        let compatID = compatID
        let textFocusID = textFocusID
        compat = overrides.first { $0.rule["id"]?.stringValue == compatID.rawValue }
        let textFocus = overrides.first { $0.rule["id"]?.stringValue == textFocusID.rawValue }
        hasTextFocusRule = textFocus != nil
        typeAnyway = [compat, textFocus].contains { $0?.rule["action"]?["requireTextFocus"] == Self.never }
    }

    /// The rule with `requireTextFocus: never` added to its action; nil when the rule has no action object.
    static func withTypeAnyway(_ rule: JSONValue) -> JSONValue? {
        guard var object = rule.objectValue, var action = object["action"]?.objectValue else { return nil }
        action["requireTextFocus"] = never
        object["action"] = .object(action)
        return .object(object)
    }
}

extension CompatibilityModeChoice {
    /// `.automatic` removes the compatibility fields; the others write `user.compat.<bundle>` dated today. A
    /// "type here anyway" already in force for the app is kept in the same rule (PLT-R540, PLT-R520).
    public func commands(
        for bundle: BundleKey, overrides: [StoredRuleOverride], at date: Date, timeZone: TimeZone = .current
    ) -> [CompatibilityModeCommand] {
        let state = AppOverrideState(bundle: bundle, overrides: overrides)
        let day = Self.day(date, timeZone: timeZone)
        var commands: [CompatibilityModeCommand] = []
        if let chosen = overrideRule(for: bundle, date: day) {
            let rule = state.typeAnyway ? AppOverrideState.withTypeAnyway(chosen) ?? chosen : chosen
            commands.append(.add(StoredRuleOverride(createdAt: date, rule: rule)))
            if state.hasTextFocusRule { commands.append(.remove(state.textFocusID)) }
            return commands
        }
        if state.typeAnyway, !state.hasTextFocusRule,
            let rule = TextFocusOverride.rule(for: bundle, strategy: AppOverrideState.automaticStrategy, date: day)
        {
            commands.append(.add(StoredRuleOverride(createdAt: date, rule: rule)))
        }
        if state.compat != nil { commands.append(.remove(state.compatID)) }
        return commands
    }
}

/// The status line's "type here anyway" (PLT-R540): `requireTextFocus: never` for the app.
public enum TypeHereAnyway {
    /// With a compatibility mode in force the mode's rule gains `requireTextFocus: never` and keeps its strategy,
    /// pacing and "set by you on" date; otherwise `user.textfocus.<bundle>` keeps `strategy`, the strategy the
    /// app resolves to today, so nothing else changes. A pair left by an earlier version is folded into one.
    public static func commands(
        for bundle: BundleKey, strategy: InjectionStrategy, overrides: [StoredRuleOverride], at date: Date,
        timeZone: TimeZone = .current
    ) -> [CompatibilityModeCommand] {
        let state = AppOverrideState(bundle: bundle, overrides: overrides)
        if let compat = state.compat {
            guard let rule = AppOverrideState.withTypeAnyway(compat.rule) else { return [] }
            var commands: [CompatibilityModeCommand] = [
                .add(StoredRuleOverride(createdAt: compat.createdAt, rule: rule))
            ]
            if state.hasTextFocusRule { commands.append(.remove(state.textFocusID)) }
            return commands
        }
        let day = CompatibilityModeChoice.day(date, timeZone: timeZone)
        guard let rule = TextFocusOverride.rule(for: bundle, strategy: strategy, date: day) else { return [] }
        return [.add(StoredRuleOverride(createdAt: date, rule: rule))]
    }
}
