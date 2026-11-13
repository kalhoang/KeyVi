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

/// PRD-R34, PRD-R36, PLT-R541: a guided result in the app's slot whose action is none of the pane's modes (for
/// example `backspaceReplace` with `axSelection`) is listed as "set by the guided test" with the date it was
/// applied, so the pane never shows "Tự động" while a user override is in force. "Tự động" still removes it.
@Suite struct GuidedTestStateTests {
    let app = BundleKey(rawValue: "com.example.Chat")!
    let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13

    func guidedRule(_ best: GuidedTestCandidate) -> Rule {
        GuidedTestRunner.suggestion(
            context: MatchContext(bundle: app, appVersion: nil, macOS: LooseVersion("27.1")!, engine: .electron),
            best: best, appVersion: nil, macOS: "27.1", date: "2026-11-13", includeURLPrefix: nil)
    }

    func applied(_ best: GuidedTestCandidate) async throws -> (SettingsStoreHarness, AppsPaneRow?) {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        await harness.store.addRuleOverride(try #require(GuidedTestOverride.stored(guidedRule(best), at: date)))
        let state = await harness.store.state
        let row = AppsPaneModel.rows(appModes: state.appModes, overrides: state.ruleOverrides, matrix: nil, today: date)
            .first { $0.bundle == app }
        return (harness, row)
    }

    @Test(arguments: [
        GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0),
        GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .placeholder, interEventDelayUs: 0),
        GuidedTestCandidate(strategy: .axReplace, inlineCompletion: .none, interEventDelayUs: 0),
        GuidedTestCandidate(strategy: .passThrough, inlineCompletion: .none, interEventDelayUs: 0),
        // Pacing other than the pane's 5 ms is not "type more slowly", and 5 ms with a handling is not either.
        GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .none, interEventDelayUs: 2_000),
        GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 5_000),
        GuidedTestCandidate(strategy: .selectReplace, inlineCompletion: .none, interEventDelayUs: 2_000),
    ])
    func aResultOutsideTheModesIsSetByTheGuidedTest(_ best: GuidedTestCandidate) async throws {
        let (_, row) = try await applied(best)
        let listed = try #require(row, "the app is listed although the per-app memory does not know it")
        #expect(listed.compatibilityMode == .guidedTest)
        #expect(listed.compatibilitySetOn == date)
    }

    /// Exactly the pane's action shows as that mode (the guided test found what the pane would write).
    @Test func exactlyThePanesTypeSlowerActionIsTypeSlower() async throws {
        let paced = GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .none, interEventDelayUs: 5_000)
        let (_, row) = try await applied(paced)
        #expect(row?.compatibilityMode == .typeSlower)
    }

    @Test func thePaneOffersTheStateOnlyWhileItIsInForce() {
        #expect(CompatibilityModeChoice.choices == [.automatic, .typeSlower, .selectThenType, .pasteText])
        #expect(
            CompatibilityModeChoice.options(current: .guidedTest) == CompatibilityModeChoice.choices + [.guidedTest])
        for choice in CompatibilityModeChoice.choices {
            #expect(CompatibilityModeChoice.options(current: choice) == CompatibilityModeChoice.choices)
        }
        #expect(CompatibilityModeChoice.guidedTest.title == .compatGuidedTest)
        #expect(CompatibilityModeChoice.guidedTest.explanation == .compatGuidedTestExplanation)
        #expect(!CompatibilityModeChoice.guidedTest.needsClipboardExplanation)
    }

    /// Choosing the state again writes nothing: it is a result, not a mode the pane can write.
    @Test func choosingTheStateAgainKeepsTheResult() async throws {
        let (harness, _) = try await applied(
            GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0))
        let before = await harness.store.state.ruleOverrides
        #expect(CompatibilityModeChoice.guidedTest.commands(for: app, overrides: before, at: date).isEmpty)
        let state = await SettingsCommands(store: harness.store).setCompatibility(.guidedTest, for: app, at: date)
        #expect(state.ruleOverrides == before)
    }

    @Test func automaticRemovesTheResult() async throws {
        let (harness, _) = try await applied(
            GuidedTestCandidate(strategy: .axReplace, inlineCompletion: .none, interEventDelayUs: 0))
        let state = await SettingsCommands(store: harness.store).setCompatibility(.automatic, for: app, at: date)
        #expect(state.ruleOverrides.isEmpty)
        #expect(AppsPaneModel.rows(appModes: state.appModes, overrides: [], matrix: nil, today: date).isEmpty)
    }

    /// The bug report picker lists the same apps as the pane (PRD-R47 item 1).
    @Test func theReportPickerListsTheApp() async throws {
        let (harness, _) = try await applied(
            GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0))
        let state = await harness.store.state
        #expect(AppsPaneModel.orderedBundles(appModes: state.appModes, overrides: state.ruleOverrides) == [app])
    }
}

/// "Use this for me now" keeps "type here anyway" (PLT-R540, PLT-R520, PLT-R521): an app-slot guided result
/// replaces `user.compat.<bundle>` and would leave `user.textfocus.<bundle>` next to it, two bundle-only rules that
/// tie (the smaller id wins and a health event is recorded on every focus change). Like the Apps pane, the result
/// carries `requireTextFocus: never` and the text-focus rule is removed.
@Suite struct UseThisForMeNowTests {
    let app = BundleKey(rawValue: "com.example.Chat")!
    let date = Date(timeIntervalSince1970: 1_794_528_000)  // 2026-11-13
    static let axSelection = GuidedTestCandidate(
        strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0)

    var blindContext: MatchContext {
        MatchContext(bundle: app, appVersion: nil, macOS: LooseVersion("27.1")!, engine: .electron)
    }

    /// Resolution runs as for a native app: the shipped Electron rule already types without a text field, which
    /// would hide whether "type here anyway" survived. The guided rules match the bundle only.
    var nativeContext: MatchContext {
        MatchContext(bundle: app, appVersion: nil, macOS: LooseVersion("27.1")!, engine: .native)
    }

    func guidedRule(_ context: MatchContext? = nil) -> Rule {
        GuidedTestRunner.suggestion(
            context: context ?? blindContext, best: Self.axSelection, appVersion: nil, macOS: "27.1",
            date: "2026-11-13", includeURLPrefix: nil)
    }

    func loaded() async -> SettingsCommands {
        let harness = SettingsStoreHarness()
        _ = await harness.store.load()
        return SettingsCommands(store: harness.store)
    }

    func resolve(_ state: SettingsState, _ context: MatchContext? = nil) throws -> ResolvedDecision {
        let (rules, rejected) = RulesLoader.decodeOverrides(state.ruleOverrides.map(\.rule))
        #expect(rejected.isEmpty)
        let set = try RuleSet(document: EmbeddedRules.minimal, overrides: rules, optedIn: [])
        return set.resolve(context ?? nativeContext)
    }

    @Test func theResultKeepsTypeHereAnywayAndReplacesItsRule() async throws {
        let commands = await loaded()
        _ = await commands.typeHereAnyway(for: app, strategy: .selectReplace, at: date)
        var state = await commands.useGuidedTestResult(guidedRule(), at: date)
        #expect(
            state.ruleOverrides.map { $0.rule["id"]?.stringValue } == [
                CompatibilityModeChoice.ruleID(for: app).rawValue
            ])
        var decision = try resolve(state)
        #expect(decision.tieLoser == nil)
        #expect(decision.requireTextFocus == .never)
        #expect(decision.strategy == .backspaceReplace && decision.params.inlineCompletion == .axSelection)
        // The pane still shows the result, and "Tự động" removes only the result: "type here anyway" stays.
        #expect(
            AppsPaneModel.rows(appModes: state.appModes, overrides: state.ruleOverrides, matrix: nil, today: date)
                .first?.compatibilityMode == .guidedTest)
        state = await commands.setCompatibility(.automatic, for: app, at: date)
        decision = try resolve(state)
        #expect(state.ruleOverrides.count == 1 && decision.requireTextFocus == .never)
        #expect(decision.params.inlineCompletion != .axSelection)
    }

    /// "Type here anyway" folded into a compatibility mode is kept when the result replaces the mode.
    @Test func theResultKeepsTypeHereAnywayOfTheModeItReplaces() async throws {
        let commands = await loaded()
        _ = await commands.setCompatibility(.pasteText, for: app, at: date)
        _ = await commands.typeHereAnyway(for: app, strategy: .selectReplace, at: date)
        let state = await commands.useGuidedTestResult(guidedRule(), at: date)
        #expect(state.ruleOverrides.count == 1)
        let decision = try resolve(state)
        #expect(decision.tieLoser == nil && decision.requireTextFocus == .never)
        #expect(decision.strategy == .backspaceReplace && decision.params.inlineCompletion == .axSelection)
    }

    @Test func withoutTypeHereAnywayTheResultIsStoredAsSuggested() async throws {
        let commands = await loaded()
        let rule = guidedRule()
        let state = await commands.useGuidedTestResult(rule, at: date)
        #expect(state.ruleOverrides == [try #require(GuidedTestOverride.stored(rule, at: date))])
        #expect(try resolve(state).requireTextFocus != .never)
    }

    /// A result for "only this kind of field" outranks the app's rule instead of tying with it: the app's
    /// "type here anyway" rule is left alone.
    @Test func aFieldScopedResultLeavesTheAppsRuleAlone() async throws {
        let commands = await loaded()
        _ = await commands.typeHereAnyway(for: app, strategy: .selectReplace, at: date)
        var field = blindContext
        field.role = "AXTextArea"
        let rule = guidedRule(field)
        #expect(rule.id != CompatibilityModeChoice.ruleID(for: app))
        let state = await commands.useGuidedTestResult(rule, at: date)
        #expect(state.ruleOverrides.count == 2)
        #expect(
            state.ruleOverrides.contains { $0.rule["id"]?.stringValue == TextFocusOverride.ruleID(for: app).rawValue })
        #expect(try resolve(state).requireTextFocus == .never, "other fields of the app keep typing anyway")
    }

    /// The pure decision: add before remove, so the app is never without its override in between.
    @Test func theCommandsAddBeforeTheyRemove() throws {
        let textFocus = try #require(TextFocusOverride.rule(for: app, strategy: .selectReplace, date: "2026-11-12"))
        let overrides = [StoredRuleOverride(createdAt: date.addingTimeInterval(-60), rule: textFocus)]
        let commands = UseThisForMeNow.commands(for: guidedRule(), overrides: overrides, at: date)
        guard commands.count == 2, case .add(let stored) = commands[0] else {
            Issue.record("expected add then remove, got \(commands)")
            return
        }
        #expect(commands[1] == .remove(TextFocusOverride.ruleID(for: app)))
        #expect(stored.createdAt == date)
        #expect(stored.rule["action"]?["requireTextFocus"] == .string("never"))
        #expect(stored.rule["id"] == .string(CompatibilityModeChoice.ruleID(for: app).rawValue))
    }
}
