// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R357: `features.lookaheadRevision` (default true) resolves with the precedence of `restoreHotkey` and is off for
// strategies other than `backspaceReplace` and `selectReplace`; the seeded compat/rules.json turns it off in the
// `restoreHotkey: false` groups (terminals, IDEs and code editors including the VS Code family and Antigravity,
// launchers, games, remote desktop); compat-lint knows the flag. The bundle IDs are fixtures checked against
// compat/rules.json (PLT-R501).

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct RulesFeatureFlagTests {
    /// Every app whose rule turns the restore key off also turns revisions off.
    @Test(arguments: RestoreHotkeyExclusionTests.excluded)
    func revisionsAreOffWhereTheRestoreKeyIsOff_PLTR357(_ app: RestoreHotkeyExclusionTests.App) throws {
        let decision = try Build.seededRuleSet().resolve(Build.context(bundle: app.bundle, engine: app.engine))
        #expect(decision.rule == ruleID(app.rule))
        #expect(!decision.features.lookaheadRevision)
    }

    @Test(arguments: [
        "com.apple.Spotlight", "com.apple.campo", "com.raycast.macos", "com.runningwithcrayons.Alfred",
    ])
    func revisionsAreOffInLaunchers(_ bundle: String) throws {
        let decision = try Build.seededRuleSet().resolve(Build.context(bundle: bundle))
        #expect(!decision.features.lookaheadRevision && !decision.features.restoreHotkey)
    }

    /// Chat apps, browsers and native text views keep the default: on (D29 decides).
    @Test func revisionsStayOnElsewhere() throws {
        let rules = try Build.seededRuleSet()
        #expect(rules.resolve(Build.context(bundle: "com.apple.TextEdit")).features.lookaheadRevision)
        #expect(
            rules.resolve(Build.context(bundle: "com.tinyspeck.slackmacgap", engine: .electron)).features
                .lookaheadRevision)
        let telegramWeb = rules.resolve(
            Build.context(bundle: "com.google.Chrome", engine: .chromium, url: "https://web.telegram.org/a/"))
        #expect(telegramWeb.strategy == .selectReplace && telegramWeb.features.lookaheadRevision)
    }

    /// Same precedence as `restoreHotkey`: the winning rule's value, else true; any strategy other than
    /// backspaceReplace or selectReplace turns it off, also in a user override.
    @Test func resolutionFollowsTheRuleAndTheStrategy() throws {
        let match = RuleMatch(bundleIds: [bundleKey("com.example.editor")])
        let rows: [(RuleAction, Bool)] = [
            (RuleAction(strategy: .backspaceReplace), true),
            (RuleAction(strategy: .selectReplace), true),
            (RuleAction(strategy: .backspaceReplace, features: RuleFeatures(lookaheadRevision: false)), false),
            (RuleAction(strategy: .axReplace, features: RuleFeatures(lookaheadRevision: true)), false),
            (RuleAction(strategy: .paste, requiresUserOptIn: true), false),
            (RuleAction(strategy: .passThrough), false),
        ]
        for (action, expected) in rows {
            // A paste rule applies only once the user opted in (PLT-R460).
            let rules = try Build.ruleSet(
                [Build.rule("app.rule", match: match, action: action)], optedIn: [ruleID("app.rule")])
            let decision = rules.resolve(Build.context())
            #expect(decision.strategy == action.strategy)
            #expect(decision.features.lookaheadRevision == expected, "\(action.strategy)")
        }
        let overridden = try Build.ruleSet(
            [Build.rule("app.rule", match: match)],
            overrides: [Build.userRule("user.app", match: match, action: RuleAction(strategy: .axReplace))])
        #expect(!overridden.resolve(Build.context()).features.lookaheadRevision)
        #expect(try Build.ruleSet([]).resolve(Build.context()).features.lookaheadRevision)
    }

    /// The key decodes (strict decoding rejects unknown keys) and round-trips.
    @Test func theFlagDecodes() throws {
        let json = #"{"strategy":"backspaceReplace","features":{"restoreHotkey":false,"lookaheadRevision":false}}"#
        let action = try JSONDecoder().decode(RuleAction.self, from: Data(json.utf8))
        #expect(action.features == RuleFeatures(restoreHotkey: false, lookaheadRevision: false))
    }

    /// compat-lint: the flag on with a strategy that cannot carry it, or left on where the restore key is off.
    @Test func lintReportsContradictions() throws {
        let match = RuleMatch(bundleIds: [bundleKey("com.example.editor")])
        let cases: [(RuleAction, LintCode?)] = [
            (
                RuleAction(strategy: .axReplace, features: RuleFeatures(lookaheadRevision: true)),
                .lookaheadRevisionWithoutEditStrategy
            ),
            (
                RuleAction(strategy: .backspaceReplace, features: RuleFeatures(restoreHotkey: false)),
                .lookaheadRevisionWithoutRestoreHotkey
            ),
            (
                RuleAction(
                    strategy: .backspaceReplace, features: RuleFeatures(restoreHotkey: false, lookaheadRevision: false)),
                nil
            ),
            (RuleAction(strategy: .passThrough, features: RuleFeatures(restoreHotkey: false)), nil),
        ]
        for (action, code) in cases {
            let document = Build.document([Build.rule("app.rule", match: match, action: action)])
            let linter = RulesLinter(
                rules: document, matrix: nil, scenarioIDs: ["app.rule"], today: day("2026-11-15"), releaseMode: false)
            let codes = Set(linter.run().map(\.code))
            let revisionCodes = codes.intersection([
                .lookaheadRevisionWithoutEditStrategy, .lookaheadRevisionWithoutRestoreHotkey,
            ])
            #expect(revisionCodes == Set([code].compactMap { $0 }), "\(action)")
        }
    }

    /// compat-lint, PLT-R357: RV5 of ENG-R828 runs in the code context whatever `lookaheadRevision` says (D29 alone,
    /// `EngineConfiguration.lineStartRevision`), so a code-context rule must use a strategy that carries a revision.
    @Test func lintRequiresAnEditStrategyForTheCodeContext() throws {
        let match = RuleMatch(bundleIds: [bundleKey("com.example.editor")])
        let cases: [(RuleAction, Bool)] = [
            (RuleAction(strategy: .axReplace, engineContext: .code), true),
            (RuleAction(strategy: .passThrough, engineContext: .code), true),
            (RuleAction(strategy: .backspaceReplace, engineContext: .code), false),
            (RuleAction(strategy: .selectReplace, engineContext: .code), false),
            (RuleAction(strategy: .axReplace, engineContext: .general), false),
            (RuleAction(strategy: .axReplace), false),
        ]
        for (action, flagged) in cases {
            let document = Build.document([Build.rule("app.rule", match: match, action: action)])
            let linter = RulesLinter(
                rules: document, matrix: nil, scenarioIDs: ["app.rule"], today: day("2026-11-16"), releaseMode: false)
            let findings = linter.run().filter { $0.code == .codeContextWithoutEditStrategy }
            #expect(findings.isEmpty == !flagged, "\(action)")
            #expect(findings.allSatisfy { $0.severity == .error }, "\(action)")
        }
    }

    /// The shipped file passes the new checks.
    @Test func theSeededRulesPassTheRevisionChecks() throws {
        let linter = RulesLinter(
            rules: try Build.seededDocument(), matrix: nil, scenarioIDs: [], today: day("2026-11-15"),
            releaseMode: false)
        let codes = linter.run().map(\.code)
        #expect(!codes.contains(.lookaheadRevisionWithoutEditStrategy))
        #expect(!codes.contains(.lookaheadRevisionWithoutRestoreHotkey))
        #expect(!codes.contains(.codeContextWithoutEditStrategy))
    }
}
