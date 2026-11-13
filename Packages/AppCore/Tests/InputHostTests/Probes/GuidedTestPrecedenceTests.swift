// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1205 step 4, PLT-R540, PLT-R520 and PLT-R521: when AX exposes no role, subrole, identifier or DOM classes,
// the guided suggestion cannot be scoped to "only this kind of field". It used to be a bundle-only rule that tied
// (score 4) with the app's other bundle-only user overrides (`user.compat.<bundle>` from the Apps pane,
// `user.textfocus.<bundle>` from "type anyway"), so the lexicographically smaller id won and every focus change
// recorded a tie. The suggestion now also matches the engine fingerprint it was measured on (+2): it outranks
// the plain app-scope override deterministically, without a tie.

import AppModel
import CompatRules
import Foundation
import Testing

@testable import InputHost

@Suite("Guided test suggestion precedence (PLT-R520, PLT-R521)")
struct GuidedTestPrecedenceTests {
    static let bundle = GuidedFixture.browser

    /// Focus with a bundle but nothing AX exposes about the field.
    static let blindContext = MatchContext(
        bundle: bundle, appVersion: LooseVersion("131.0"), macOS: LooseVersion("27.1")!, engine: .electron)

    static let defaults = RuleDefaults(
        strategy: .backspaceReplace, params: StrategyParams(), fallback: [.passThrough], defaultMode: .inherit,
        requireTextFocus: .byEngine, verifyReentry: .whenReadable)

    static func appScopeOverride(_ id: String, action: RuleAction) -> Rule {
        Rule(
            id: RuleID(rawValue: id)!, summary: "App-scope override", match: RuleMatch(bundleIds: [bundle]),
            action: action, provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-01")))
    }

    static let compatMode = appScopeOverride(
        "user.compat.com.example.Browser",
        action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(interEventDelayUs: 5_000)))
    static let typeAnyway = appScopeOverride(
        "user.textfocus.com.example.Browser", action: RuleAction(strategy: .backspaceReplace, requireTextFocus: .never))

    static func suggestion(_ context: MatchContext) -> Rule {
        GuidedTestRunner.suggestion(
            context: context, best: GuidedFixture.axSelection, appVersion: "131.0", macOS: "27.1",
            date: "2026-11-13", includeURLPrefix: nil)
    }

    static func ruleSet(overrides: [Rule]) throws -> RuleSet {
        let document = RulesDocument(
            schemaVersion: 1, rulesetVersion: "2026.11.0", defaults: defaults, bundleGroups: [:],
            conflictingInputApps: [], secureInputHints: [], rules: [])
        return try RuleSet(document: document, overrides: overrides, optedIn: [])
    }

    @Test func blindFieldSuggestionMatchesTheAppAndItsEngine() throws {
        let rule = Self.suggestion(Self.blindContext)
        #expect(rule.match.bundleIds == [Self.bundle])
        #expect(rule.match.engines == [.electron])
        #expect(rule.match.ax == nil && rule.match.web == nil && rule.match.titlePattern == nil)
        #expect(try GuidedFixture.schemaErrors(rule).isEmpty)
    }

    /// The guided result wins over either app-scope override, whatever their ids, and no tie is recorded.
    @Test(arguments: [compatMode, typeAnyway])
    func blindFieldSuggestionOutranksTheAppScopeOverride(_ appScope: Rule) throws {
        let guided = Self.suggestion(Self.blindContext)
        for overrides in [[appScope, guided], [guided, appScope]] {
            let decision = try Self.ruleSet(overrides: overrides).resolve(Self.blindContext)
            #expect(decision.rule == guided.id)
            #expect(decision.source == .user)
            #expect(decision.params.inlineCompletion == .axSelection)
            #expect(decision.tieLoser == nil)
        }
    }

    /// A field-scoped suggestion already outranks the app-scope override through its AX terms; it gains no
    /// engine term, so its id and match stay those of earlier versions.
    @Test func fieldScopedSuggestionIsUnchanged() throws {
        var field = Self.blindContext
        field.role = "AXTextArea"
        let guided = Self.suggestion(field)
        #expect(guided.match.engines == nil)
        let decision = try Self.ruleSet(overrides: [Self.compatMode, guided]).resolve(field)
        #expect(decision.rule == guided.id && decision.tieLoser == nil)
        // In another kind of field of the same app the field-scoped suggestion does not apply.
        var other = Self.blindContext
        other.role = "AXTextField"
        #expect(try Self.ruleSet(overrides: [Self.compatMode, guided]).resolve(other).rule == Self.compatMode.id)
    }

    /// A different engine fingerprint (the app was rebuilt on another engine) is not what the test measured: the
    /// app-scope override applies again.
    @Test func blindFieldSuggestionStopsMatchingOnAnotherEngine() throws {
        let guided = Self.suggestion(Self.blindContext)
        var rebuilt = Self.blindContext
        rebuilt.engine = .native
        #expect(try Self.ruleSet(overrides: [Self.compatMode, guided]).resolve(rebuilt).rule == Self.compatMode.id)
    }
}
