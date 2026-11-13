// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1205 flow logic: nothing is typed before the user confirms the field is empty and safe, the human
// fallback question, early stop at the first pass, interruptions, the host-level page address (ADR 0312) and
// the step 5 offers.

import AppModel
import CompatRules
import Foundation
import Injection
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

@Suite("This app misbehaves flow (PLT-R1205)")
struct MisbehavesFlowTests {
    @Test func targetComesFromTheFocusSnapshot() {
        let decision = HostDecision(
            plan: .default, variant: .default, requireTextFocus: .never, verifyReentry: .never,
            restoreHotkeyEnabled: true, rule: RuleID(rawValue: "electron.default"), source: .shipped, specificity: 2)
        let app = FocusedApp(pid: 3, bundle: GuidedFixture.browser, appVersion: nil, engine: .native)
        let focus = FocusSnapshot(
            generation: FocusGeneration(rawValue: 5), app: app, field: .unknown, decision: decision, mode: .vietnamese,
            modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero, pause: nil)
        let target = MisbehavesTarget(focus: focus)
        #expect(target.app == app && target.rule?.rawValue == "electron.default" && target.source == .shipped)
        #expect(target.isNativeApp)
        #expect(target.focusGeneration == FocusGeneration(rawValue: 5))
        let context = target.matchContext(macOS: "not a version")
        #expect(context.bundle == GuidedFixture.browser && context.engine == .native)
    }

    @Test func typingNeedsTheExplicitConfirmation() {
        var flow = MisbehavesFlow(target: GuidedFixture.target())
        #expect(flow.step == .describe && flow.pendingCandidate == nil)
        flow.confirmFieldIsEmptyAndSafe()  // ignored before the guided test was requested
        #expect(flow.step == .describe)
        flow.requestGuidedTest()
        #expect(flow.step == .confirmField && flow.pendingCandidate == nil)
        flow.record(.passedByReadback)  // no run is due yet
        #expect(flow.results.allSatisfy { $0 == nil })
        flow.confirmFieldIsEmptyAndSafe()
        #expect(flow.pendingCandidate?.index == 0)
        #expect(flow.pendingCandidate?.candidate == flow.candidates[0])
    }

    @Test(arguments: [true, false])
    func noGuidedTestInSecureFieldsOrWithoutAnApp(secure: Bool) {
        var target = GuidedFixture.target(secure: secure)
        if !secure { target.app = nil }
        var flow = MisbehavesFlow(target: target)
        flow.requestGuidedTest()
        #expect(flow.step == .describe)
        #expect(!target.canRunGuidedTest)
    }

    @Test func failuresAdvanceAndTheFirstPassFinishes() {
        var flow = started()
        flow.record(.failedByReadback(residue: false))
        #expect(flow.step == .testing(1))
        flow.record(.passedByReadback)
        #expect(flow.step == .finished)
        #expect(flow.best == flow.candidates[1])
        flow.record(.passedByReadback)  // nothing pending any more
        #expect(flow.results[2] == nil)
    }

    @Test func allFailingEndsWithoutASuggestion() {
        var flow = started()
        for _ in flow.candidates { flow.record(.failedByReadback(residue: true)) }
        #expect(flow.step == .finished && flow.best == nil)
        #expect(flow.suggestion(macOS: "27.1", date: "2026-11-13") == nil)
        #expect(flow.offers(hasRepository: false) == [.copyReport])
    }

    @Test func humanQuestionWaitsForTheAnswer() {
        var flow = started()
        flow.record(.needsHumanAnswer)
        #expect(flow.step == .askHuman(0) && flow.questionCandidate == flow.candidates[0])
        flow.record(.passedByReadback)  // ignored while asking
        #expect(flow.step == .askHuman(0))
        flow.answer(seesCanary: true)
        #expect(flow.step == .finished && flow.results[0] == .humanSaidYes)
        flow.answer(seesCanary: false)  // no question pending
        #expect(flow.results[0] == .humanSaidYes)
        #expect(flow.questionCandidate == nil)
    }

    @Test func aFieldWithTextStopsTheTest() {
        var flow = started()
        flow.record(.fieldNotEmpty)
        #expect(flow.step == .interrupted(.fieldNotEmpty))
        #expect(flow.pendingCandidate == nil)
    }

    @Test func interruptionsStopTypingButNotAFinishedFlow() {
        var flow = started()
        flow.interrupt(.focusChanged)
        #expect(flow.step == .interrupted(.focusChanged))
        flow.interrupt(.cancelled)
        #expect(flow.step == .interrupted(.focusChanged))
        var finished = started()
        finished.record(.passedByReadback)
        finished.interrupt(.cancelled)
        #expect(finished.step == .finished)
    }

    @Test func pageAddressIsOptInAndHostLevel() throws {
        // ADR 0312: a URL prefix only when the user opted in, cut to scheme and host.
        var flow = started()
        flow.record(.passedByReadback)
        flow.pageAddress = "https://Docs.Example.com/document/d/zqxkanary/edit?usp=sharing#heading"
        #expect(flow.pageAddressPrefix == nil)
        let without = try #require(flow.suggestion(macOS: "27.1", date: "2026-11-13"))
        #expect(without.match.web == nil)
        flow.includePageAddress = true
        #expect(flow.pageAddressPrefix == "https://docs.example.com/")
        let with = try #require(flow.suggestion(macOS: "27.1", date: "2026-11-13"))
        #expect(with.match.web?.urlPrefixes == ["https://docs.example.com/"])
        #expect(try GuidedFixture.schemaErrors(with).isEmpty)
        flow.pageAddress = "file:///Users/someone/zqxkanary.txt"
        #expect(flow.pageAddressPrefix == nil)
    }

    @Test func offersFollowTheResult() {
        var flow = started()
        #expect(flow.offers(hasRepository: true) == [.copyReport, .openGitHubIssue])
        flow.record(.failedByReadback(residue: false))
        flow.record(.passedByReadback)
        #expect(!flow.couldNotReproduce)
        #expect(flow.offers(hasRepository: true) == MisbehavesOffer.allCases)
        #expect(flow.offers(hasRepository: false) == [.useForMe, .copySuggestion, .copyReport])
    }

    @Test func aPassingCurrentPlanIsNotOfferedAsAnOverride() {
        // PLT-R540: an override equal to the shipped decision fixes nothing and shadows later shipped rules.
        var flow = started()
        flow.record(.passedByReadback)
        #expect(flow.step == .finished && flow.couldNotReproduce)
        #expect(flow.offers(hasRepository: true) == [.copyReport, .openGitHubIssue])
        // When the current plan cannot type (pass-through), the default plan standing in for it is a real change.
        var passThrough = MisbehavesFlow(
            target: GuidedFixture.target(
                plan: InjectionPlan(strategy: .passThrough, parameters: .defaults, fallback: [])))
        passThrough.requestGuidedTest()
        passThrough.confirmFieldIsEmptyAndSafe()
        passThrough.record(.humanSaidYes)
        #expect(passThrough.step == .finished && !passThrough.couldNotReproduce)
        #expect(passThrough.offers(hasRepository: false) == [.useForMe, .copySuggestion, .copyReport])
    }

    @Test func aStoppedCandidateMeansTheFocusMoved() {
        var flow = started()
        flow.record(.stopped)
        #expect(flow.step == .interrupted(.focusChanged))
        #expect(flow.results[0] == .stopped && flow.pendingCandidate == nil)
        #expect(!flow.couldNotReproduce && flow.best == nil)
    }

    @Test func theGuidedTestNeedsTheHostPassThrough() {
        // PLT-R1205 step 3: without the host hook the runner's events would be transformed, so no offer.
        let target = GuidedFixture.target()
        #expect(target.offersGuidedTest(hostPassThroughAvailable: true))
        #expect(!target.offersGuidedTest(hostPassThroughAvailable: false))
        #expect(!GuidedFixture.target(secure: true).offersGuidedTest(hostPassThroughAvailable: true))
    }

    private func started() -> MisbehavesFlow {
        var flow = MisbehavesFlow(target: GuidedFixture.target())
        flow.requestGuidedTest()
        flow.confirmFieldIsEmptyAndSafe()
        return flow
    }
}

@Suite("Guided test suggestion (PLT-R1205 step 4, ADR 0312)")
struct GuidedTestSuggestionTests {
    static let context = MatchContext(
        bundle: GuidedFixture.browser, appVersion: LooseVersion("131.0"), macOS: LooseVersion("27.1")!,
        engine: .chromium, role: "AXTextField", subrole: "AXSearchField", identifier: nil,
        domClasses: ["omnibox", "zqx"], editable: true, documentURL: "https://zqxkanary.example/secret",
        windowTitle: "zqxkanarytitle")

    @Test func matchActionAndProvenance() throws {
        let rule = GuidedTestRunner.suggestion(
            context: Self.context, best: GuidedFixture.axSelection, appVersion: "131.0", macOS: "27.1",
            date: "2026-11-13", includeURLPrefix: nil)
        #expect(rule.id.rawValue.hasPrefix("user.guided.com.example.Browser."))
        #expect(rule.match.bundleIds == [GuidedFixture.browser])
        #expect(rule.match.engines == nil && rule.match.bundleGroup == nil && rule.match.titlePattern == nil)
        #expect(rule.match.ax?.roles == ["AXTextField"] && rule.match.ax?.subroles == ["AXSearchField"])
        #expect(rule.match.ax?.domClasses == ["omnibox", "zqx"] && rule.match.ax?.identifiers == nil)
        #expect(rule.match.web == nil)  // the context's document URL is never copied
        #expect(rule.action.strategy == .backspaceReplace)
        #expect(rule.action.params == StrategyParams(inlineCompletion: .axSelection))
        #expect(
            rule.provenance
                == .userSuggestion(
                    UserProvenance(source: "user-suggestion", appVersion: "131.0", macOS: "27.1", date: "2026-11-13")))
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        #expect(!json.contains("zqxkanary"))
        #expect(try GuidedFixture.schemaErrors(rule).isEmpty)
    }

    /// PLT-R540 "only this kind of field": each field kind of an app has its own override ID, so a guided test
    /// in the address bar and one in a web editor coexist; the same kind of field keeps the same ID.
    @Test func eachFieldKindGetsItsOwnOverrideID() {
        var editor = Self.context
        editor.role = "AXTextArea"
        editor.subrole = nil
        editor.domClasses = ["editor"]
        func id(_ context: MatchContext) -> String {
            GuidedTestRunner.suggestion(
                context: context, best: GuidedFixture.plain, appVersion: nil, macOS: "27.1", date: "2026-11-13",
                includeURLPrefix: nil
            ).id.rawValue
        }
        #expect(id(Self.context) != id(editor))
        #expect(id(Self.context) == id(Self.context))
        #expect(id(editor).hasPrefix("user.guided.com.example.Browser."))
    }

    /// PLT-R540, SettingsStore replaces an override with the same ID: two field kinds must both stay stored.
    @Test func twoFieldKindsOfOneAppAreBothStored() async throws {
        var editor = Self.context
        editor.role = "AXTextArea"
        editor.subrole = nil
        let store = SettingsStoreHarness()
        _ = await store.store.load()
        for context in [Self.context, editor] {
            let rule = GuidedTestRunner.suggestion(
                context: context, best: GuidedFixture.plain, appVersion: nil, macOS: "27.1", date: "2026-11-13",
                includeURLPrefix: nil)
            let stored = try #require(GuidedTestOverride.stored(rule, at: Date(timeIntervalSince1970: 0)))
            await store.store.addRuleOverride(stored)
        }
        #expect(await store.store.state.ruleOverrides.count == 2)
    }

    @Test func identifierWinsOverDOMClassesAndPacingIsKept() {
        var context = Self.context
        context.identifier = "search"
        let paced = GuidedTestCandidate(strategy: .selectReplace, inlineCompletion: .none, interEventDelayUs: 2_000)
        let rule = GuidedTestRunner.suggestion(
            context: context, best: paced, appVersion: nil, macOS: "27.1", date: "2026-11-13", includeURLPrefix: nil)
        #expect(rule.match.ax?.identifiers == ["search"] && rule.match.ax?.domClasses == nil)
        #expect(rule.action.params == StrategyParams(interEventDelayUs: 2_000))
    }

    @Test func defaultCandidateHasNoParamsAndBundlelessAppsMatchTheEngine() throws {
        var context = Self.context
        context.bundle = nil
        context.role = nil
        context.subrole = nil
        context.domClasses = []
        let rule = GuidedTestRunner.suggestion(
            context: context, best: GuidedFixture.plain, appVersion: nil, macOS: "27.1", date: "2026-11-13",
            includeURLPrefix: "https://zqx.example/path")
        #expect(rule.id.rawValue.hasPrefix("user.guided.app.") && rule.id.rawValue.utf8.count == 24)
        #expect(rule.action.params == nil)
        #expect(rule.match.engines == [.chromium] && rule.match.ax == nil)
        #expect(rule.match.web?.urlPrefixes == ["https://zqx.example/"])
        #expect(try GuidedFixture.schemaErrors(rule).isEmpty)
    }

    @Test(arguments: [
        ("https://user:pw@Example.COM:8443/a/b?q=1#f", "https://example.com:8443/"),
        ("  http://example.org  ", "http://example.org/"),
    ])
    func addressesAreCutToTheHost(input: String, expected: String) {
        #expect(GuidedTestSuggestion.hostLevelPrefix(input) == expected)
    }

    @Test(arguments: ["", "example.com", "ftp://example.com/", "https:///nohost", "javascript:alert(1)"])
    func nonWebAddressesAreDropped(input: String) {
        #expect(GuidedTestSuggestion.hostLevelPrefix(input) == nil)
    }

    @Test func ruleIDsStayWithinTheGrammar() throws {
        let match = GuidedTestSuggestion.match(Self.context, urlPrefix: nil)
        let suffix = "." + GuidedTestSuggestion.signatureHash(RuleSet.signature(of: match))
        #expect(suffix.utf8.count == 9)
        let hashed = BundleKey.executable(sha256Hex: String(repeating: "ab", count: 32))
        #expect(
            GuidedTestSuggestion.ruleID(for: hashed, match: match).rawValue == "user.guided.sha256_"
                + String(repeating: "ab", count: 32) + suffix)
        let dotted = BundleKey(rawValue: "com..example-1_x")
        #expect(
            GuidedTestSuggestion.ruleID(for: dotted, match: match).rawValue == "user.guided.com.example-1_x" + suffix)
        let long = BundleKey(rawValue: "com." + String(repeating: "a", count: 200))
        #expect(long != nil)
        let longID = GuidedTestSuggestion.ruleID(for: long, match: match).rawValue
        #expect(longID.utf8.count == 128)
        #expect(longID.hasSuffix(suffix))
    }
}
