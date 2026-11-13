// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Rule decision -> tap decision (PLT-R386, PLT-R460) and the text-focus gate (PLT-R386, PLT-R387). Pure.

import AppModel
import CompatRules
import Injection

enum HostDecisionMapping {
    static func map(_ decision: ResolvedDecision, engine: EngineFingerprint, optedIntoPaste: Bool) -> HostDecision {
        // PLT-R460: a rule that offers `paste` behind an opt-in does not paste until the user opted in.
        // The first non-paste fallback is then promoted to the primary and leaves the fallback chain, so the
        // worker does not retry it.
        let pasteAllowed = !decision.requiresUserOptIn || optedIntoPaste
        var fallback = pasteAllowed ? decision.fallback : decision.fallback.filter { $0 != .paste }
        var strategy = decision.strategy
        if strategy == .paste, !pasteAllowed {
            strategy = fallback.first ?? .backspaceReplace
            fallback = Array(fallback.dropFirst())
        }
        let params = decision.params
        let parameters = InjectionParameters(
            unicodeChunk: params.unicodeChunk, interEventDelayUs: params.interEventDelayUs,
            postDeleteSettleUs: params.postDeleteSettleUs, firstEditDelayUs: params.firstEditDelayUs,
            inlineCompletion: params.inlineCompletion, allowMultiCharEvents: params.allowMultiCharEvents,
            allowSplit: params.allowSplit, longTextThreshold: params.longTextThreshold,
            restoreDelayMs: params.restoreDelayMs, verifyAfterEdit: params.verifyAfterEdit,
            pasteOptedIn: optedIntoPaste)
        return HostDecision(
            plan: InjectionPlan(strategy: strategy, parameters: parameters, fallback: fallback),
            variant: EngineVariant(
                appContext: decision.engineContext, englishRestore: decision.features.englishRestore,
                macros: decision.features.macros),
            requireTextFocus: concrete(decision.requireTextFocus, engine: engine),
            verifyReentry: decision.verifyReentry, restoreHotkeyEnabled: decision.features.restoreHotkey,
            rule: decision.rule, source: decision.source, specificity: decision.specificity)
    }

    /// PLT-R386 default: `whenKnown` where AX is reliable (native, Catalyst), `never` elsewhere.
    static func concrete(_ value: RequireTextFocus, engine: EngineFingerprint) -> RequireTextFocus {
        guard value == .byEngine else { return value }
        return engine == .native || engine == .catalyst ? .whenKnown : .never
    }

    /// PRD-R21 "Bỏ qua ứng dụng này": a user override with strategy `passThrough` (PLT-R390).
    static func ignoring(_ decision: HostDecision) -> HostDecision {
        var result = decision
        result.plan = InjectionPlan(strategy: .passThrough, parameters: decision.plan.parameters, fallback: [])
        result.rule = FocusRuleIDs.userIgnore
        result.source = .user
        return result
    }
}

enum FocusRuleIDs {
    /// Rule ID shown for the per-app "ignore" choice (a user override, PLT-R390).
    static let userIgnore = RuleID(rawValue: "user.ignore")!
    /// A `passThrough` decision without a rule ID can only come from the defaults block.
    static let defaults = RuleID(rawValue: "defaults")!
}

/// PLT-R386 text-context gating over the AX facts of the focused element.
enum TextFocusGate {
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let searchFieldSubrole = "AXSearchField"
    static let secureSubrole = "AXSecureTextField"
    /// Reported when the application itself is the focused element: there is no focused element.
    static let applicationRole = "AXApplication"

    /// Editable text: a text role, the search-field subrole, or an element AX marks editable. An explicit
    /// "not editable" never overrides a text role (VERIFY: the editable attribute differs between engines).
    static func isEditable(_ field: FieldContext) -> Bool {
        field.editable == true || field.role.map(textRoles.contains) == true || field.subrole == searchFieldSubrole
    }

    /// True when the requirement says this field must pass through.
    static func blocks(_ requirement: RequireTextFocus, field: FieldContext) -> Bool {
        switch requirement {
        case .never, .byEngine:
            return false
        case .whenKnown:
            // Only when AX positively reports an element that is not editable text.
            return field.axAvailability == .available && field.role != nil && !isEditable(field)
        case .always:
            return !(field.axAvailability == .available && isEditable(field))
        }
    }

    /// Focus-derived pause, in the PLT-R398A order: secure field first, then pass-through rule, then text focus.
    static func pause(field: FieldContext, decision: HostDecision) -> PauseReason? {
        if field.secure { return .secureField }
        if decision.plan.strategy == .passThrough { return .passThroughRule(decision.rule ?? FocusRuleIDs.defaults) }
        return blocks(decision.requireTextFocus, field: field) ? .noTextFocus : nil
    }
}
