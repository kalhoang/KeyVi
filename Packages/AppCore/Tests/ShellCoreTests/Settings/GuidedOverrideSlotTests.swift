// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R540 "reset to automatic", PRD-R36, PLT-R521: a guided test run where AX exposes nothing about the field
// stores its result in the app's one "this app" override, `user.compat.<bundle>`. The Apps pane's later choice
// replaces it and "Tự động" removes it, so the pane never shows a mode that is not in force because a second
// rule outranks it. Driven through the real store, commands and rule set.

import AppModel
import CompatRules
import Foundation
import InputHost
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct GuidedOverrideSlotTests {
    let app = BundleKey(rawValue: "com.example.Chat")!
    let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    var blindContext: MatchContext {
        MatchContext(bundle: app, appVersion: nil, macOS: LooseVersion("27.1")!, engine: .electron)
    }

    func guidedRule(_ best: GuidedTestCandidate) -> Rule {
        GuidedTestRunner.suggestion(
            context: blindContext, best: best, appVersion: nil, macOS: "27.1", date: "2026-11-13",
            includeURLPrefix: nil)
    }

    static let axSelection = GuidedTestCandidate(
        strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0)

    func harness() async -> SettingsStoreHarness {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        return harness
    }

    /// "Use this for me now" (App composition): the rule as a stored override, upserted by id.
    func applyGuided(_ rule: Rule, to harness: SettingsStoreHarness) async throws {
        await harness.store.addRuleOverride(try #require(GuidedTestOverride.stored(rule, at: date)))
    }

    func resolve(_ state: SettingsState) throws -> ResolvedDecision {
        let (rules, rejected) = RulesLoader.decodeOverrides(state.ruleOverrides.map(\.rule))
        #expect(rejected.isEmpty)
        let set = try RuleSet(document: EmbeddedRules.minimal, overrides: rules, optedIn: [])
        return set.resolve(blindContext)
    }

    @Test(arguments: [
        BundleKey(rawValue: "com.example.Chat")!, BundleKey(rawValue: "com..example-1_x")!,
        BundleKey.executable(sha256Hex: String(repeating: "ab", count: 32))!,
        BundleKey(rawValue: "com." + String(repeating: "a", count: 200))!,
    ])
    func guidedSlotIDIsTheAppsPaneID(_ bundle: BundleKey) {
        let rule = GuidedTestRunner.suggestion(
            context: MatchContext(bundle: bundle, appVersion: nil, macOS: LooseVersion("27.1")!, engine: .electron),
            best: Self.axSelection, appVersion: nil, macOS: "27.1", date: "2026-11-13", includeURLPrefix: nil)
        #expect(rule.id == CompatibilityModeChoice.ruleID(for: bundle))
    }

    @Test func aLaterCompatibilityModeReplacesTheGuidedResult() async throws {
        let harness = await harness()
        try await applyGuided(guidedRule(Self.axSelection), to: harness)
        let commands = SettingsCommands(store: harness.store)
        let state = await commands.setCompatibility(.typeSlower, for: app, at: date)
        #expect(state.ruleOverrides.count == 1)
        let decision = try resolve(state)
        #expect(decision.rule == CompatibilityModeChoice.ruleID(for: app) && decision.tieLoser == nil)
        #expect(decision.params.interEventDelayUs == 5_000)
        #expect(decision.params.inlineCompletion != .axSelection)
    }

    @Test func automaticRemovesTheGuidedResult() async throws {
        let harness = await harness()
        try await applyGuided(guidedRule(Self.axSelection), to: harness)
        let commands = SettingsCommands(store: harness.store)
        let state = await commands.setCompatibility(.automatic, for: app, at: date)
        #expect(state.ruleOverrides.isEmpty)
        #expect(try resolve(state).source != .user)
    }

    @Test func aGuidedResultReplacesTheCompatibilityMode() async throws {
        let harness = await harness()
        let commands = SettingsCommands(store: harness.store)
        _ = await commands.setCompatibility(.pasteText, for: app, at: date)
        try await applyGuided(guidedRule(Self.axSelection), to: harness)
        let state = await commands.state()
        #expect(state.ruleOverrides.count == 1)
        let decision = try resolve(state)
        #expect(decision.strategy == .backspaceReplace && decision.params.inlineCompletion == .axSelection)
        #expect(decision.tieLoser == nil)
    }

    /// A guided result that is one of the pane's modes shows as that mode, with its date.
    @Test func aGuidedResultThatIsAModeShowsInTheAppsPane() async throws {
        let harness = await harness()
        let select = GuidedTestCandidate(strategy: .selectReplace, inlineCompletion: .none, interEventDelayUs: 0)
        try await applyGuided(guidedRule(select), to: harness)
        let state = await harness.store.state
        let row = AppsPaneModel.rows(appModes: state.appModes, overrides: state.ruleOverrides, matrix: nil, today: date)
            .first { $0.bundle == app }
        #expect(row?.compatibilityMode == .selectThenType)
        #expect(row?.compatibilitySetOn != nil)
    }
}
