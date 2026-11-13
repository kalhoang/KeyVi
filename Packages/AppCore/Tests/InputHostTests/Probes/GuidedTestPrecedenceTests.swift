// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1205 step 4, PLT-R540, PLT-R520 and PLT-R521: when AX exposes no role, subrole, identifier or DOM classes,
// the guided suggestion cannot be scoped to "only this kind of field", so it is a "this app" override. An app has
// one such slot, `user.compat.<bundle>`, the rule the Apps pane writes, shows, replaces and removes with "reset to
// automatic" (PRD-R36). A second bundle-only rule for the same app would tie with it (score 4, smaller id wins,
// a tie recorded on every focus change), and a rule outranking it would leave the Apps pane without effect. The
// guided result therefore takes the slot itself: it replaces the app's compatibility mode, and a later choice in
// the Apps pane replaces or removes it (end to end in ShellCoreTests/Settings/GuidedOverrideSlotTests.swift).

import AppModel
import CompatRules
import Foundation
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

@Suite("Guided test suggestion precedence (PLT-R520, PLT-R521, PLT-R540)")
struct GuidedTestPrecedenceTests {
    static let bundle = GuidedFixture.browser
    static let slotID = "user.compat.com.example.Browser"

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
        slotID, action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(interEventDelayUs: 5_000)))

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

    /// The Apps pane's slot: same id, bundle-only match, so the pane's next choice replaces it.
    @Test func blindFieldSuggestionTakesTheAppsPaneSlot() throws {
        let rule = Self.suggestion(Self.blindContext)
        #expect(rule.id.rawValue == Self.slotID)
        #expect(rule.match == RuleMatch(bundleIds: [Self.bundle]))
        #expect(rule.summary == GuidedTestSuggestion.summary)
        #expect(rule.action.params == StrategyParams(inlineCompletion: .axSelection))
        #expect(try GuidedFixture.schemaErrors(rule).isEmpty)
    }

    /// Stored over the app's compatibility mode (SettingsStore replaces an override with the same id): one rule,
    /// the guided result, and no tie.
    @Test func blindFieldSuggestionReplacesTheCompatibilityMode() async throws {
        let store = SettingsStoreHarness()
        _ = await store.store.load()
        let guided = Self.suggestion(Self.blindContext)
        for rule in [Self.compatMode, guided] {
            await store.store.addRuleOverride(try #require(GuidedTestOverride.stored(rule, at: Date())))
        }
        let stored = await store.store.state.ruleOverrides
        #expect(stored.count == 1)
        let decoded = RulesLoader.decodeOverrides(stored.map(\.rule))
        #expect(decoded.rejected.isEmpty && decoded.rules == [guided])
        let decision = try Self.ruleSet(overrides: decoded.rules).resolve(Self.blindContext)
        #expect(decision.rule == guided.id && decision.source == .user && decision.tieLoser == nil)
        #expect(decision.params.inlineCompletion == .axSelection)
    }

    /// Not tied to the engine it was measured on: the Apps pane's own rule is not either, and the slot is one
    /// rule whoever wrote it last.
    @Test func blindFieldSuggestionAppliesWhateverTheEngine() throws {
        let guided = Self.suggestion(Self.blindContext)
        var rebuilt = Self.blindContext
        rebuilt.engine = .native
        #expect(try Self.ruleSet(overrides: [guided]).resolve(rebuilt).rule == guided.id)
    }

    /// A field-scoped suggestion outranks the app-scope override through its AX terms and keeps its own
    /// `user.guided.<bundle>.<hash>` id, so it coexists with the app's compatibility mode.
    @Test func fieldScopedSuggestionIsUnchanged() throws {
        var field = Self.blindContext
        field.role = "AXTextArea"
        let guided = Self.suggestion(field)
        #expect(guided.id.rawValue.hasPrefix("user.guided.com.example.Browser."))
        #expect(guided.match.engines == nil)
        let decision = try Self.ruleSet(overrides: [Self.compatMode, guided]).resolve(field)
        #expect(decision.rule == guided.id && decision.tieLoser == nil)
        // In another kind of field of the same app the field-scoped suggestion does not apply.
        var other = Self.blindContext
        other.role = "AXTextField"
        #expect(try Self.ruleSet(overrides: [Self.compatMode, guided]).resolve(other).rule == Self.compatMode.id)
    }

    /// Without a bundle ID there is no Apps pane row: the engine stays the only identity of the suggestion.
    @Test func bundlelessSuggestionKeepsTheEngine() {
        var context = Self.blindContext
        context.bundle = nil
        let rule = Self.suggestion(context)
        #expect(rule.id.rawValue.hasPrefix("user.guided.app."))
        #expect(rule.match == RuleMatch(engines: [.electron]))
    }
}
