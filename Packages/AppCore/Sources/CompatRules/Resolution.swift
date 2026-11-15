// SPDX-License-Identifier: GPL-3.0-or-later
//
// Rule resolution (02-platform.md 5.5). Runs on the ax thread on focus change, never per keystroke (PLT-R523).

public import AppModel

/// Matcher input built by the focus tracker (5.2). `documentURL` and `windowTitle` are transient: used in
/// memory for matching and never stored in snapshots, logs or reports (PLT-R383).
public struct MatchContext: Sendable, Hashable {
    public var bundle: BundleKey?
    public var appVersion: LooseVersion?
    public var macOS: LooseVersion
    public var engine: EngineFingerprint
    public var appCategory: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var domClasses: [String]
    public var ancestorRoles: [String]  // up to 6 levels
    public var editable: Bool?
    public var documentURL: String?
    public var windowTitle: String?

    public init(
        bundle: BundleKey?, appVersion: LooseVersion?, macOS: LooseVersion, engine: EngineFingerprint,
        appCategory: String? = nil, role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        domClasses: [String] = [], ancestorRoles: [String] = [], editable: Bool? = nil,
        documentURL: String? = nil, windowTitle: String? = nil
    ) {
        self.bundle = bundle
        self.appVersion = appVersion
        self.macOS = macOS
        self.engine = engine
        self.appCategory = appCategory
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domClasses = domClasses
        self.ancestorRoles = ancestorRoles
        self.editable = editable
        self.documentURL = documentURL
        self.windowTitle = windowTitle
    }
}

/// Fully resolved parameters with caps applied (PLT-R404, PLT-R408, PLT-R480, PLT-R461).
public struct ResolvedParams: Sendable, Hashable, Codable {
    public var unicodeChunk: Int
    public var interEventDelayUs: Int
    public var postDeleteSettleUs: Int
    public var firstEditDelayUs: Int
    public var inlineCompletion: InlineCompletionMode
    public var allowMultiCharEvents: Bool
    public var allowSplit: Bool
    public var longTextThreshold: Int
    public var restoreDelayMs: Int
    public var verifyAfterEdit: Bool

    public static let maximumDelayUs = 50_000
    public static let maximumUnicodeChunk = 20

    /// The 5.4 `defaults.params` plus the section 4 defaults for keys the defaults block omits.
    public static let defaults = ResolvedParams(
        unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0, inlineCompletion: .none,
        allowMultiCharEvents: false, allowSplit: false, longTextThreshold: 64, restoreDelayMs: 400,
        verifyAfterEdit: false)

    public init(
        unicodeChunk: Int, interEventDelayUs: Int, postDeleteSettleUs: Int, firstEditDelayUs: Int,
        inlineCompletion: InlineCompletionMode, allowMultiCharEvents: Bool, allowSplit: Bool, longTextThreshold: Int,
        restoreDelayMs: Int, verifyAfterEdit: Bool
    ) {
        self.unicodeChunk = unicodeChunk
        self.interEventDelayUs = interEventDelayUs
        self.postDeleteSettleUs = postDeleteSettleUs
        self.firstEditDelayUs = firstEditDelayUs
        self.inlineCompletion = inlineCompletion
        self.allowMultiCharEvents = allowMultiCharEvents
        self.allowSplit = allowSplit
        self.longTextThreshold = longTextThreshold
        self.restoreDelayMs = restoreDelayMs
        self.verifyAfterEdit = verifyAfterEdit
    }
}

public struct ResolvedFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool
    public var macros: Bool
    public var englishRestore: Bool
    public var restoreHotkey: Bool
    /// PLT-R357: the rule allows revising the previous word, and its strategy is one whose edits a revision can
    /// ride on (`backspaceReplace` or `selectReplace`). The host ANDs it with the user's D29.
    public var lookaheadRevision: Bool

    /// 5.4: all true except `autoCapitalize`.
    public static let defaults = ResolvedFeatures(
        autoCapitalize: false, macros: true, englishRestore: true, restoreHotkey: true, lookaheadRevision: true)

    public init(
        autoCapitalize: Bool, macros: Bool, englishRestore: Bool, restoreHotkey: Bool, lookaheadRevision: Bool = true
    ) {
        self.autoCapitalize = autoCapitalize
        self.macros = macros
        self.englishRestore = englishRestore
        self.restoreHotkey = restoreHotkey
        self.lookaheadRevision = lookaheadRevision
    }
}

/// The "compatibility profile" of 03-product.md: winning rule's action applied over `defaults`.
public struct ResolvedDecision: Sendable, Hashable {
    public var rule: RuleID?
    public var source: DecisionSource
    public var specificity: Int
    public var strategy: InjectionStrategy
    public var params: ResolvedParams
    public var fallback: [InjectionStrategy]
    public var defaultMode: FirstSeenMode
    /// Never `.byEngine`: resolved with PLT-R386 (`whenKnown` for native/catalyst, else `never`).
    public var requireTextFocus: RequireTextFocus
    public var verifyReentry: VerifyReentry
    public var axEnable: AXEnableMode
    public var overlay: Bool
    public var requiresUserOptIn: Bool
    public var engineContext: EngineContextKind
    public var features: ResolvedFeatures
    /// Per-rule booleans for the snapshot (PLT-R383); the strings themselves are not kept.
    public var matchedTitle: Bool
    public var matchedURL: Bool
    /// Set when two rules tied at runtime (PLT-R521); the caller records a health event.
    public var tieLoser: RuleID?
    /// The winning user override, when `source == .user`. The diagnostics report never embeds it raw: ShellCore
    /// projects it to the typed `DiagnosticsReport.ReportedOverride` (PLT-R541, PLT-R1203, ADR 0312).
    public var userOverride: Rule?

    public init(
        rule: RuleID?, source: DecisionSource, specificity: Int, strategy: InjectionStrategy, params: ResolvedParams,
        fallback: [InjectionStrategy], defaultMode: FirstSeenMode, requireTextFocus: RequireTextFocus,
        verifyReentry: VerifyReentry, axEnable: AXEnableMode, overlay: Bool, requiresUserOptIn: Bool,
        engineContext: EngineContextKind, features: ResolvedFeatures, matchedTitle: Bool = false,
        matchedURL: Bool = false, tieLoser: RuleID? = nil, userOverride: Rule? = nil
    ) {
        self.rule = rule
        self.source = source
        self.specificity = specificity
        self.strategy = strategy
        self.params = params
        self.fallback = fallback
        self.defaultMode = defaultMode
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
        self.axEnable = axEnable
        self.overlay = overlay
        self.requiresUserOptIn = requiresUserOptIn
        self.engineContext = engineContext
        self.features = features
        self.matchedTitle = matchedTitle
        self.matchedURL = matchedURL
        self.tieLoser = tieLoser
        self.userOverride = userOverride
    }
}

/// Compiled, immutable rule set: shipped document plus user overrides plus opted-in IDs.
public struct RuleSet: Sendable {
    public init(document: RulesDocument, overrides: [Rule], optedIn: Set<RuleID>) throws(RulesValidationError) {
        self.document = document
        compiled = try CompiledRuleSet(document: document, overrides: overrides, optedIn: optedIn)
    }

    public let document: RulesDocument
    let compiled: CompiledRuleSet

    /// Specificity per PLT-R520; user overrides outrank shipped rules (PLT-R522); ties resolve to the
    /// lexicographically smaller id (PLT-R521).
    public func resolve(_ context: MatchContext) -> ResolvedDecision {
        compiled.resolve(context, defaults: document.defaults)
    }

    /// Bundles whose AX focus is observed even when not frontmost (`overlay: true`, PLT-R380).
    public var overlayBundles: Set<BundleKey> { compiled.overlayBundles }
    /// Bundles with a `titlePattern` rule: only these get title-change observers (PLT-R380).
    public var titlePatternBundles: Set<BundleKey> { compiled.titlePatternBundles }
    public var conflictingInputApps: Set<BundleKey> { compiled.conflictingInputApps }
    public func secureInputHintKey(for bundle: BundleKey) -> String? { compiled.hintKey(for: bundle) }
    /// `bundleGroups["webkitBrowsers"]`, consumed by the fingerprinter (PLT-R510).
    public var webkitBrowsers: Set<BundleKey> { compiled.webkitBrowsers }
    /// Match signature used for duplicate detection (PLT-R521).
    public static func signature(of match: RuleMatch) -> String { MatchSignature.canonical(match) }
}
