// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compiled-in known-good ruleset (PLT-R503), used when the shipped compat-rules.json is missing or invalid.
// It holds the 5.4 `defaults` block and the engine-only rules of compat/rules.json (match by engine, optionally
// narrowed by AX, never by bundle, group, title or URL). It contains no bundle identifiers (PLT-R501) and no URL
// hosts (QA-R60). A test keeps it identical to the engine-only rules of the shipped file.

import AppModel

enum EmbeddedRuleset {
    static let document = RulesDocument(
        schemaVersion: RulesValidator.supportedSchemaVersion, rulesetVersion: "embedded", defaults: defaults,
        bundleGroups: [:], conflictingInputApps: [], secureInputHints: [], rules: rules)

    static let defaults = RuleDefaults(
        strategy: .backspaceReplace,
        params: StrategyParams(
            unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0,
            inlineCompletion: InlineCompletionMode.none),
        fallback: [.passThrough], defaultMode: .inherit, requireTextFocus: .byEngine, verifyReentry: .whenReadable)

    static let rules: [Rule] = [
        Rule(
            id: ruleID("browser.chromium.addressBar"),
            summary: "Chromium-family address and command bars with inline autocomplete",
            match: addressBarMatch(.chromium, roles: ["AXTextField"]),
            action: RuleAction(
                strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .axSelectionThenPlaceholder),
                features: RuleFeatures(autoCapitalize: false))),
        Rule(
            id: ruleID("browser.webkit.addressBar"),
            summary: "Safari address bar with inline autocomplete (WebKit exposes the selection through AX)",
            match: addressBarMatch(.webkitBrowser, roles: ["AXTextField"]),
            action: RuleAction(
                strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .axSelection),
                features: RuleFeatures(autoCapitalize: false))),
        Rule(
            id: ruleID("browser.gecko.urlBar"), summary: "Firefox URL bar with inline autocomplete",
            match: addressBarMatch(.gecko, roles: ["AXTextField", "AXComboBox"]),
            action: RuleAction(
                strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .axSelectionThenPlaceholder),
                features: RuleFeatures(autoCapitalize: false))),
        Rule(
            id: ruleID("electron.default"),
            summary: "Electron apps: default strategy, never enable accessibility, no text-focus gating",
            match: RuleMatch(engines: [.electron]),
            action: RuleAction(strategy: .backspaceReplace, requireTextFocus: .never, axEnable: AXEnableMode.none)),
        Rule(
            id: ruleID("jvm.default"),
            summary: "Other Java apps: paced events, no AX gating, code context (JetBrains IDEs: editor.jetbrains)",
            match: RuleMatch(engines: [.jvm]),
            action: RuleAction(
                strategy: .backspaceReplace,
                params: StrategyParams(interEventDelayUs: 1_000, postDeleteSettleUs: 2_000),
                requireTextFocus: .never, engineContext: .code)),
    ]

    private static func addressBarMatch(_ engine: EngineFingerprint, roles: [String]) -> RuleMatch {
        RuleMatch(engines: [engine], ax: AXMatch(roles: roles, ancestorRoles: ["AXToolbar"]))
    }

    private static func ruleID(_ raw: String) -> RuleID {
        guard let id = RuleID(rawValue: raw) else { preconditionFailure("invalid embedded rule id") }
        return id
    }
}
