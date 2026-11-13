// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct ResolutionTests {
    struct SpecificityCase: Sendable, CustomTestStringConvertible {
        let label: String
        let match: RuleMatch
        let context: MatchContext
        let expected: Int
        var testDescription: String { label }
    }

    static let specificityCases: [SpecificityCase] = [
        .init(
            label: "ax.identifiers +16", match: RuleMatch(ax: AXMatch(identifiers: ["search"])),
            context: Build.context(identifier: "search"), expected: 16),
        .init(
            label: "ax.domClasses +16", match: RuleMatch(ax: AXMatch(domClasses: ["cell"])),
            context: Build.context(domClasses: ["x", "cell"]), expected: 16),
        .init(
            label: "identifiers and domClasses count once",
            match: RuleMatch(ax: AXMatch(identifiers: ["i"], domClasses: ["c"])),
            context: Build.context(identifier: "i", domClasses: ["c"]), expected: 16),
        .init(
            label: "ax.roles +8", match: RuleMatch(ax: AXMatch(roles: ["AXTextField"])),
            context: Build.context(role: "AXTextField"), expected: 8),
        .init(
            label: "ax.subroles +8", match: RuleMatch(ax: AXMatch(subroles: ["AXSearchField"])),
            context: Build.context(subrole: "AXSearchField"), expected: 8),
        .init(
            label: "ax.ancestorRoles +8", match: RuleMatch(ax: AXMatch(ancestorRoles: ["AXToolbar"])),
            context: Build.context(ancestorRoles: ["AXGroup", "AXToolbar"]), expected: 8),
        .init(
            label: "roles, subroles and ancestors count once",
            match: RuleMatch(ax: AXMatch(roles: ["r"], subroles: ["s"], ancestorRoles: ["a"])),
            context: Build.context(role: "r", subrole: "s", ancestorRoles: ["a"]), expected: 8),
        .init(
            label: "web.urlPrefixes +8", match: RuleMatch(web: WebMatch(urlPrefixes: ["https://example.org/app/"])),
            context: Build.context(url: "https://example.org/app/1"), expected: 8),
        .init(
            label: "titlePattern +4 (with bundleIds +4)",
            match: RuleMatch(bundleIds: [bundleKey("com.example.editor")], titlePattern: "^Inbox"),
            context: Build.context(title: "Inbox (3)"), expected: 8),
        .init(
            label: "bundleIds +4", match: RuleMatch(bundleIds: [bundleKey("com.example.editor")]),
            context: Build.context(), expected: 4),
        .init(label: "bundleGroup +4", match: RuleMatch(bundleGroup: "editors"), context: Build.context(), expected: 4),
        .init(label: "engines +2", match: RuleMatch(engines: [.qt]), context: Build.context(engine: .qt), expected: 2),
        .init(
            label: "appCategories +1", match: RuleMatch(appCategories: ["public.app-category.games"]),
            context: Build.context(category: "public.app-category.games"), expected: 1),
        .init(
            label: "versions and editable add nothing",
            match: RuleMatch(
                appVersion: VersionRange(min: version("1.0")), macOS: VersionRange(max: version("27.9")),
                ax: AXMatch(editable: true)), context: Build.context(editable: true), expected: 0),
    ]

    /// Acceptance: every specificity term of PLT-R520.
    @Test(arguments: specificityCases)
    func specificityTerm(_ testCase: SpecificityCase) throws {
        let rules = try Build.ruleSet(
            [Build.rule("under.test", match: testCase.match)], groups: ["editors": [bundleKey("com.example.editor")]])
        let decision = rules.resolve(testCase.context)
        #expect(decision.rule == ruleID("under.test"))
        #expect(decision.source == .shipped)
        #expect(decision.specificity == testCase.expected)
    }

    @Test func higherSpecificityWins() throws {
        let rules = try Build.ruleSet([
            Build.rule("engine", match: RuleMatch(engines: [.chromium])),
            Build.rule("engine.field", match: RuleMatch(engines: [.chromium], ax: AXMatch(roles: ["AXTextField"]))),
        ])
        #expect(rules.resolve(Build.context(engine: .chromium, role: "AXTextField")).rule == ruleID("engine.field"))
        #expect(rules.resolve(Build.context(engine: .chromium, role: "AXButton")).rule == ruleID("engine"))
    }

    /// Acceptance, PLT-R522: a user override beats a more specific shipped rule.
    @Test func userOverrideBeatsMoreSpecificShippedRule() throws {
        let shipped = Build.rule(
            "precise",
            match: RuleMatch(bundleIds: [bundleKey("com.example.editor")], ax: AXMatch(identifiers: ["body"])))
        let mine = Build.userRule("user.editor", match: RuleMatch(engines: [.native]))
        let rules = try Build.ruleSet([shipped], overrides: [mine])
        let decision = rules.resolve(Build.context(identifier: "body"))
        #expect(decision.rule == ruleID("user.editor"))
        #expect(decision.source == .user)
        #expect(decision.strategy == .selectReplace)
        #expect(decision.userOverride == mine)
        #expect(decision.specificity == 2)
        let shippedOnly = rules.resolve(Build.context(engine: .qt, identifier: "body"))
        #expect(shippedOnly.rule == ruleID("precise"))
        #expect(shippedOnly.userOverride == nil)
    }

    @Test func userOverridesCompareBySpecificityThenID() throws {
        let rules = try Build.ruleSet(
            [],
            overrides: [
                Build.userRule("user.b", match: RuleMatch(engines: [.native])),
                Build.userRule("user.a", match: RuleMatch(engines: [.native])),
                Build.userRule("user.c", match: RuleMatch(bundleIds: [bundleKey("com.example.editor")])),
            ])
        #expect(rules.resolve(Build.context()).rule == ruleID("user.c"))
        let decision = rules.resolve(Build.context(bundle: "com.example.other"))
        #expect(decision.rule == ruleID("user.a"))
        #expect(decision.tieLoser == ruleID("user.b"))
    }

    /// Acceptance, PLT-R521: a runtime tie picks the smaller id and reports the loser.
    @Test func runtimeTiePicksSmallerIDAndReportsLoser() throws {
        let rules = try Build.ruleSet([
            Build.rule(
                "zeta.byVersion", match: RuleMatch(engines: [.native], appVersion: VersionRange(min: version("1")))),
            Build.rule("alpha.byOS", match: RuleMatch(engines: [.native], macOS: VersionRange(min: version("26")))),
            Build.rule("mid.byEditable", match: RuleMatch(engines: [.native], ax: AXMatch(editable: true))),
        ])
        let decision = rules.resolve(Build.context(editable: false))
        #expect(decision.rule == ruleID("alpha.byOS"))
        #expect(decision.tieLoser == ruleID("zeta.byVersion"))
        let noTie = rules.resolve(Build.context(appVersion: nil, macOS: "15.0"))
        #expect(noTie.rule == nil)
        #expect(noTie.tieLoser == nil)
    }

    @Test func noCandidateGivesDefaultsWithByEngineResolved() throws {
        let rules = try Build.ruleSet([Build.rule("qt.only", match: RuleMatch(engines: [.qt]))])
        let native = rules.resolve(Build.context(engine: .native))
        #expect(native.rule == nil)
        #expect(native.source == .default)
        #expect(native.specificity == 0)
        #expect(native.requireTextFocus == .whenKnown)  // PLT-R386
        #expect(native.params == ResolvedParams.defaults)
        #expect(native.fallback == [.passThrough])
        #expect(native.features == .defaults)
        #expect(rules.resolve(Build.context(engine: .catalyst)).requireTextFocus == .whenKnown)
        #expect(rules.resolve(Build.context(engine: .chromium)).requireTextFocus == .never)
        #expect(rules.resolve(Build.context(engine: .electron)).requireTextFocus == .never)
    }

    @Test func winningActionIsAppliedOverDefaults() throws {
        var defaults = Build.defaults
        defaults.params.restoreDelayMs = 300
        let action = RuleAction(
            strategy: .backspaceReplace, params: StrategyParams(interEventDelayUs: 1_500, allowSplit: true),
            defaultMode: .en, requireTextFocus: .byEngine, axEnable: .manual, overlay: true, requiresUserOptIn: true,
            engineContext: .code, features: RuleFeatures(macros: false))
        let rule = Build.rule("full", match: RuleMatch(engines: [.electron]), action: action)
        let rules = try RuleSet(
            document: Build.document([rule], defaults: defaults), overrides: [], optedIn: [ruleID("full")])
        let decision = rules.resolve(Build.context(engine: .electron))
        #expect(decision.params.interEventDelayUs == 1_500)
        #expect(decision.params.allowSplit)
        #expect(decision.params.restoreDelayMs == 300)  // defaults block
        #expect(decision.params.longTextThreshold == 64)  // section 4 default
        #expect(decision.fallback == [.passThrough])
        #expect(decision.defaultMode == .en)
        #expect(decision.requireTextFocus == .never)
        #expect(decision.axEnable == .manual)
        #expect(decision.overlay && decision.requiresUserOptIn)
        #expect(decision.engineContext == .code)
        #expect(
            decision.features
                == ResolvedFeatures(autoCapitalize: false, macros: false, englishRestore: true, restoreHotkey: true))
    }

    /// `requiresUserOptIn` rules and shipped `paste` rules stay inactive until opted in (PLT-R460).
    @Test func optInRulesAreInactiveUntilOptedIn() throws {
        let optIn = Build.rule(
            "remote.paste", match: RuleMatch(bundleIds: [bundleKey("com.example.remote")]),
            action: RuleAction(strategy: .paste, requiresUserOptIn: true))
        let sneaky = Build.rule(
            "remote.paste.noFlag", match: RuleMatch(bundleIds: [bundleKey("com.example.vm")]),
            action: RuleAction(strategy: .paste))
        let remote = Build.context(bundle: "com.example.remote")
        let vm = Build.context(bundle: "com.example.vm")
        let off = try Build.ruleSet([optIn, sneaky])
        #expect(off.resolve(remote).rule == nil)
        #expect(off.resolve(vm).rule == nil)
        let on = try Build.ruleSet([optIn, sneaky], optedIn: [ruleID("remote.paste"), ruleID("remote.paste.noFlag")])
        #expect(on.resolve(remote).strategy == .paste)
        #expect(on.resolve(vm).strategy == .paste)
        let user = try Build.ruleSet(
            [],
            overrides: [
                Build.userRule(
                    "user.paste", match: RuleMatch(bundleIds: [bundleKey("com.example.vm")]),
                    action: RuleAction(strategy: .paste, requiresUserOptIn: true))
            ])
        #expect(user.resolve(vm).strategy == .paste)
    }

    @Test func fieldMatchingSemantics() throws {
        let rules = try Build.ruleSet([
            Build.rule(
                "versioned",
                match: RuleMatch(
                    bundleIds: [bundleKey("com.example.editor")],
                    appVersion: VersionRange(min: version("2.0"), max: version("3.0")))),
            Build.rule("os", match: RuleMatch(engines: [.qt], macOS: VersionRange(min: version("27")))),
            Build.rule("editable", match: RuleMatch(engines: [.gecko], ax: AXMatch(editable: true))),
            Build.rule(
                "url",
                match: RuleMatch(
                    engines: [.cef], web: WebMatch(urlPrefixes: ["https://a.example/", "https://b.example/x"]))),
            Build.rule("title", match: RuleMatch(bundleIds: [bundleKey("com.example.mail")], titlePattern: "^Compose")),
        ])
        #expect(rules.resolve(Build.context(appVersion: "2.5")).rule == ruleID("versioned"))
        #expect(rules.resolve(Build.context(appVersion: "3.1")).rule == nil)
        #expect(rules.resolve(Build.context(appVersion: nil)).rule == nil)
        #expect(rules.resolve(Build.context(engine: .qt, macOS: "27.0")).rule == ruleID("os"))
        #expect(rules.resolve(Build.context(engine: .qt, macOS: "26.4")).rule == nil)
        #expect(rules.resolve(Build.context(engine: .gecko, editable: true)).rule == ruleID("editable"))
        #expect(rules.resolve(Build.context(engine: .gecko, editable: nil)).rule == nil)
        let url = rules.resolve(Build.context(engine: .cef, url: "https://b.example/x/1"))
        #expect(url.rule == ruleID("url") && url.matchedURL && !url.matchedTitle)
        #expect(rules.resolve(Build.context(engine: .cef, url: "https://b.example/y")).rule == nil)
        #expect(rules.resolve(Build.context(engine: .cef)).rule == nil)
        let title = rules.resolve(Build.context(bundle: "com.example.mail", title: "Compose: draft"))
        #expect(title.rule == ruleID("title") && title.matchedTitle && !title.matchedURL)
        #expect(rules.resolve(Build.context(bundle: "com.example.mail", title: "Inbox")).rule == nil)
        #expect(rules.resolve(Build.context(bundle: "com.example.mail")).rule == nil)
        #expect(rules.resolve(Build.context(bundle: nil)).rule == nil)
    }

    @Test func derivedSetsAndHints() throws {
        let terminal = bundleKey("com.example.terminal")
        let overlay = Build.rule(
            "panel", match: RuleMatch(bundleGroup: "panels"),
            action: RuleAction(strategy: .backspaceReplace, overlay: true))
        let directOverlay = Build.rule(
            "direct", match: RuleMatch(bundleIds: [bundleKey("com.example.launcher")]),
            action: RuleAction(strategy: .backspaceReplace, overlay: true))
        let titled = Build.rule(
            "titled", match: RuleMatch(bundleIds: [bundleKey("com.example.mail")], titlePattern: "x"))
        let document = Build.document(
            [overlay, directOverlay, titled],
            groups: ["panels": [bundleKey("com.example.panel")], "webkitBrowsers": [bundleKey("com.example.browser")]],
            conflicting: [bundleKey("com.example.ime")],
            hints: [SecureInputHint(bundleId: terminal, hintKey: "terminal.secureKeyboardEntry")])
        let rules = try RuleSet(document: document, overrides: [], optedIn: [])
        #expect(rules.overlayBundles == [bundleKey("com.example.panel"), bundleKey("com.example.launcher")])
        #expect(rules.titlePatternBundles == [bundleKey("com.example.mail")])
        #expect(rules.conflictingInputApps == [bundleKey("com.example.ime")])
        #expect(rules.webkitBrowsers == [bundleKey("com.example.browser")])
        #expect(rules.secureInputHintKey(for: terminal) == "terminal.secureKeyboardEntry")
        #expect(rules.secureInputHintKey(for: bundleKey("com.example.mail")) == nil)
        #expect(rules.document == document)
    }

    /// PLT-R521: the signature ignores list and key order but nothing else.
    @Test func signatureIsOrderInsensitive() {
        let first = RuleMatch(
            bundleIds: [bundleKey("b.b.b"), bundleKey("a.a.a")], engines: [.qt, .gecko], appCategories: ["y", "x"],
            ax: AXMatch(
                roles: ["r2", "r1"], subroles: ["s2", "s1"], identifiers: ["i2", "i1"], domClasses: ["d2", "d1"],
                ancestorRoles: ["a2", "a1"]),
            web: WebMatch(urlPrefixes: ["https://b/", "https://a/"]))
        let second = RuleMatch(
            bundleIds: [bundleKey("a.a.a"), bundleKey("b.b.b")], engines: [.gecko, .qt], appCategories: ["x", "y"],
            ax: AXMatch(
                roles: ["r1", "r2"], subroles: ["s1", "s2"], identifiers: ["i1", "i2"], domClasses: ["d1", "d2"],
                ancestorRoles: ["a1", "a2"]),
            web: WebMatch(urlPrefixes: ["https://a/", "https://b/"]))
        #expect(RuleSet.signature(of: first) == RuleSet.signature(of: second))
        var different = second
        different.ax?.editable = true
        #expect(RuleSet.signature(of: first) != RuleSet.signature(of: different))
        #expect(RuleSet.signature(of: RuleMatch()) == "{}")
    }

    /// PLT-R404, PLT-R408, PLT-R480, PLT-R461 caps hold even for values that bypass validation.
    @Test func resolvedParametersAreCapped() {
        let wild = ResolvedParams(
            unicodeChunk: 99, interEventDelayUs: -5, postDeleteSettleUs: 90_000, firstEditDelayUs: 60_000,
            inlineCompletion: .axSelection, allowMultiCharEvents: true, allowSplit: false, longTextThreshold: 0,
            restoreDelayMs: 10_000, verifyAfterEdit: true)
        let capped = wild.capped()
        #expect(capped.unicodeChunk == ResolvedParams.maximumUnicodeChunk)
        #expect(capped.interEventDelayUs == 0)
        #expect(capped.postDeleteSettleUs == ResolvedParams.maximumDelayUs)
        #expect(capped.firstEditDelayUs == ResolvedParams.maximumDelayUs)
        #expect(capped.longTextThreshold == 1)
        #expect(capped.restoreDelayMs == 5_000)
        #expect(capped.inlineCompletion == .axSelection && capped.allowMultiCharEvents && capped.verifyAfterEdit)
    }

    /// RuleSet is an immutable value shared across threads (resolution on the ax thread, reads elsewhere).
    @Test func concurrentResolutionIsConsistent() async throws {
        let rules = try Build.seededRuleSet()
        let context = Build.context(bundle: "com.apple.Terminal")
        let results = await withTaskGroup(of: RuleID?.self) { group in
            for _ in 0..<64 { group.addTask { rules.resolve(context).rule } }
            return await group.reduce(into: Set<RuleID?>()) { $0.insert($1) }
        }
        #expect(results == [ruleID("terminal.default")])
    }
}
