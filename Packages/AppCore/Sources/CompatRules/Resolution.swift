// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public struct ResolvedFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool
    public var macros: Bool
    public var englishRestore: Bool
    public var restoreHotkey: Bool
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
    /// The winning rule as raw JSON, for the diagnostics report of the reported app (PLT-R541).
    public var ruleJSON: JSONValue?
}

/// Compiled, immutable rule set: shipped document plus user overrides plus opted-in IDs.
public struct RuleSet: Sendable {
    public init(document: RulesDocument, overrides: [Rule], optedIn: Set<RuleID>) throws(RulesValidationError) {
        unimplemented()
    }

    public let document: RulesDocument

    /// Specificity per PLT-R520; user overrides outrank shipped rules (PLT-R522); ties resolve to the
    /// lexicographically smaller id (PLT-R521).
    public func resolve(_ context: MatchContext) -> ResolvedDecision { unimplemented() }

    /// Bundles whose AX focus is observed even when not frontmost (`overlay: true`, PLT-R380).
    public var overlayBundles: Set<BundleKey> { unimplemented() }
    /// Bundles with a `titlePattern` rule: only these get title-change observers (PLT-R380).
    public var titlePatternBundles: Set<BundleKey> { unimplemented() }
    public var conflictingInputApps: Set<BundleKey> { unimplemented() }
    public func secureInputHintKey(for bundle: BundleKey) -> String? { unimplemented() }
    /// `bundleGroups["webkitBrowsers"]`, consumed by the fingerprinter (PLT-R510).
    public var webkitBrowsers: Set<BundleKey> { unimplemented() }
    /// Match signature used for duplicate detection (PLT-R521).
    public static func signature(of match: RuleMatch) -> String { unimplemented() }
}
