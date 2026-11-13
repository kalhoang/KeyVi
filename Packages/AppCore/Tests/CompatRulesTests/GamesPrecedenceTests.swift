// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R520 exception (decision of the product owner, 13/11/2026, Q48): a candidate that matches by
// `appCategories` with a `passThrough` action (the games rule) wins over every candidate whose score comes only
// from `engines`, so a game built on JVM, Electron, CEF or Chromium passes keys through instead of getting its
// engine's strategy. Ties keep PLT-R521, and user overrides still outrank shipped rules (PLT-R522).

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct GamesPrecedenceTests {
    static let gameCategory = "public.app-category.action-games"

    static func gamesRule(_ id: String = "games.passThrough") -> Rule {
        Build.rule(
            id, match: RuleMatch(appCategories: [gameCategory, "public.app-category.games"]),
            action: RuleAction(strategy: .passThrough, fallback: [], defaultMode: .en))
    }

    static func engineRule(_ engine: EngineFingerprint, id: String? = nil) -> Rule {
        Build.rule(
            id ?? "engine." + engine.rawValue, match: RuleMatch(engines: [engine]),
            action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(interEventDelayUs: 1_000)))
    }

    static func game(_ engine: EngineFingerprint, bundle: String = "com.example.game") -> MatchContext {
        Build.context(bundle: bundle, engine: engine, category: gameCategory)
    }

    /// Every engine family: the games rule beats the engine-only rule of the game's engine (JVM, Electron, CEF
    /// and Chromium are the families the decision names; the others follow the same rule).
    @Test(arguments: EngineFingerprint.allCases)
    func gameCategoryBeatsAnEngineOnlyRule_PLTR520(_ engine: EngineFingerprint) throws {
        let rules = try Build.ruleSet([Self.engineRule(engine), Self.gamesRule()])
        let decision = rules.resolve(Self.game(engine))
        #expect(decision.rule == ruleID("games.passThrough"))
        #expect(decision.strategy == .passThrough)
        #expect(decision.specificity == Specificity.appCategory)  // the reported score stays the rule's own
        #expect(decision.tieLoser == nil)
    }

    /// Outside a game the engine rule still applies: the exception only removes engine-only candidates when a
    /// games rule matches.
    @Test(arguments: [EngineFingerprint.jvm, .electron, .cef, .chromium])
    func engineRuleStillAppliesOutsideGames(_ engine: EngineFingerprint) throws {
        let rules = try Build.ruleSet([Self.engineRule(engine), Self.gamesRule()])
        let decision = rules.resolve(Build.context(bundle: "com.example.tool", engine: engine))
        #expect(decision.rule == ruleID("engine." + engine.rawValue))
        #expect(decision.strategy == .backspaceReplace)
    }

    /// The shipped data: a game built on JVM or Electron passes through instead of getting `jvm.default` or
    /// `electron.default`.
    @Test(arguments: [EngineFingerprint.jvm, .electron, .cef, .chromium])
    func seededGamesRuleBeatsSeededEngineRules(_ engine: EngineFingerprint) throws {
        let decision = try Build.seededRuleSet().resolve(Self.game(engine))
        #expect(decision.rule == ruleID("games.passThrough"))
        #expect(decision.strategy == .passThrough && decision.defaultMode == .en)
        #expect(!decision.features.restoreHotkey && !decision.features.macros)
        #expect(decision.tieLoser == nil)
    }

    /// Only engine-only candidates lose: a rule that also scores by AX structure, bundle or URL keeps the plain
    /// highest-score order.
    @Test func moreSpecificRulesStillBeatTheGamesRule() throws {
        let field = Build.rule(
            "engine.field", match: RuleMatch(engines: [.chromium], ax: AXMatch(roles: ["AXTextField"])))
        let bundle = Build.rule("bundle.game", match: RuleMatch(bundleIds: [bundleKey("com.example.game")]))
        let rules = try Build.ruleSet([field, bundle, Self.engineRule(.chromium), Self.gamesRule()])
        var context = Self.game(.chromium)
        #expect(rules.resolve(context).rule == ruleID("bundle.game"))
        context.role = "AXTextField"
        #expect(rules.resolve(context).rule == ruleID("engine.field"))
    }

    /// The exception needs a `passThrough` action: a category rule with another strategy does not beat the
    /// engine rule.
    @Test func categoryRuleWithoutPassThroughDoesNotBeatTheEngine() throws {
        let category = Build.rule("category.typing", match: RuleMatch(appCategories: [Self.gameCategory]))
        let rules = try Build.ruleSet([Self.engineRule(.jvm), category])
        #expect(rules.resolve(Self.game(.jvm)).rule == ruleID("engine.jvm"))
    }

    /// Tie-break: two games rules of the same score tie by the lexicographically smaller id and report the
    /// other games rule as the tie loser (PLT-R521); the engine-only rules that lost to the exception are never
    /// reported, even when they tie with each other.
    @Test func tiesBetweenGamesRulesKeepThePLTR521Order() throws {
        let rules = try Build.ruleSet([
            Self.engineRule(.jvm, id: "engine.a"), Self.engineRule(.jvm, id: "engine.b"),
            Self.gamesRule("games.z"), Self.gamesRule("games.m"),
        ])
        let decision = rules.resolve(Self.game(.jvm))
        #expect(decision.rule == ruleID("games.m"))
        #expect(decision.tieLoser == ruleID("games.z"))
        let single = try Build.ruleSet([
            Self.engineRule(.jvm, id: "engine.a"), Self.engineRule(.jvm, id: "engine.b"), Self.gamesRule(),
        ])
        let solo = single.resolve(Self.game(.jvm))
        #expect(solo.rule == ruleID("games.passThrough"))
        #expect(solo.tieLoser == nil)
    }

    /// The exception only removes the engine-only candidates: what remains resolves exactly as it would with no
    /// engine rule at all. Another category rule of the same score is a PLT-R521 tie with the games rule (smaller
    /// id wins, the tie is recorded), with or without an engine rule for the game's engine; the engine rule's
    /// presence never decides between two category rules.
    @Test func categoryTiesResolveAsWithoutTheEngineRule() throws {
        let typing = Build.rule(
            "category.aaa", match: RuleMatch(appCategories: [Self.gameCategory]),
            action: RuleAction(strategy: .backspaceReplace))
        let withEngine = try Build.ruleSet([Self.engineRule(.electron), typing, Self.gamesRule()])
            .resolve(Self.game(.electron))
        let withoutEngine = try Build.ruleSet([typing, Self.gamesRule()]).resolve(Self.game(.electron))
        #expect(withEngine == withoutEngine)
        #expect(withEngine.rule == ruleID("category.aaa"))
        #expect(withEngine.tieLoser == ruleID("games.passThrough"))
    }

    /// PLT-R522: a user override outranks every shipped rule, the games rule included; within the user's own
    /// overrides the exception applies the same way.
    @Test func userOverridesStillOutrankShippedRules() throws {
        let userEngine = Build.userRule("user.engine", match: RuleMatch(engines: [.jvm]))
        let shipped = try Build.ruleSet([Self.gamesRule()], overrides: [userEngine])
        #expect(shipped.resolve(Self.game(.jvm)).rule == ruleID("user.engine"))
        let userGames = Build.userRule(
            "user.games", match: RuleMatch(appCategories: [Self.gameCategory]),
            action: RuleAction(strategy: .passThrough))
        let both = try Build.ruleSet([Self.engineRule(.jvm)], overrides: [userEngine, userGames])
        #expect(both.resolve(Self.game(.jvm)).rule == ruleID("user.games"))
    }
}
