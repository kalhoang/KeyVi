// SPDX-License-Identifier: GPL-3.0-or-later
//
// compat-rules.json schema, version 1 (02-platform.md 5.4). Field names, optionality and enum spellings match
// the spec table exactly; compat/schema/rules.schema.json is the JSON Schema twin (CI validates both ways).

public import AppModel

public struct RulesDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var rulesetVersion: String  // "2026.11.0"
    public var defaults: RuleDefaults
    /// Named bundle groups. Reserved: `terminals` (5.4 example), `webkitBrowsers` (PLT-R510 fingerprint).
    public var bundleGroups: [String: [BundleKey]]
    /// Other Vietnamese input apps to warn about (PLT-R399).
    public var conflictingInputApps: [BundleKey]
    public var secureInputHints: [SecureInputHint]
    public var rules: [Rule]

    public init(
        schemaVersion: Int, rulesetVersion: String, defaults: RuleDefaults, bundleGroups: [String: [BundleKey]],
        conflictingInputApps: [BundleKey], secureInputHints: [SecureInputHint], rules: [Rule]
    ) {
        self.schemaVersion = schemaVersion
        self.rulesetVersion = rulesetVersion
        self.defaults = defaults
        self.bundleGroups = bundleGroups
        self.conflictingInputApps = conflictingInputApps
        self.secureInputHints = secureInputHints
        self.rules = rules
    }
}

public struct RuleDefaults: Sendable, Hashable, Codable {
    public var strategy: InjectionStrategy
    public var params: StrategyParams
    public var fallback: [InjectionStrategy]
    public var defaultMode: FirstSeenMode
    public var requireTextFocus: RequireTextFocus
    public var verifyReentry: VerifyReentry

    public init(
        strategy: InjectionStrategy, params: StrategyParams, fallback: [InjectionStrategy],
        defaultMode: FirstSeenMode, requireTextFocus: RequireTextFocus, verifyReentry: VerifyReentry
    ) {
        self.strategy = strategy
        self.params = params
        self.fallback = fallback
        self.defaultMode = defaultMode
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
    }
}

public struct SecureInputHint: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    /// String Catalog key suffix, for example `terminal.secureKeyboardEntry` (PLT-R397, PLT-R398C).
    public var hintKey: String

    public init(
        bundleId: BundleKey, hintKey: String
    ) {
        self.bundleId = bundleId
        self.hintKey = hintKey
    }
}

public struct Rule: Sendable, Hashable, Codable {
    public var id: RuleID
    public var summary: String
    public var match: RuleMatch
    public var action: RuleAction
    /// Required for shipped rules (PLT-R505); user overrides carry `userSuggestion` provenance (PLT-R1205).
    public var provenance: RuleProvenance?
    /// Required for shipped rules (PLT-R505).
    public var test: RuleTest?

    public init(
        id: RuleID, summary: String, match: RuleMatch, action: RuleAction, provenance: RuleProvenance? = nil,
        test: RuleTest? = nil
    ) {
        self.id = id
        self.summary = summary
        self.match = match
        self.action = action
        self.provenance = provenance
        self.test = test
    }
}

public struct RuleMatch: Sendable, Hashable, Codable {
    public var bundleIds: [BundleKey]?
    public var bundleGroup: String?
    public var engines: [EngineFingerprint]?
    public var appCategories: [String]?
    public var appVersion: VersionRange?
    public var macOS: VersionRange?
    public var ax: AXMatch?
    public var web: WebMatch?
    /// Shipped rules only, only with `bundleIds`, at most 200 characters, compiled at load (PLT-R502).
    public var titlePattern: String?

    public init(
        bundleIds: [BundleKey]? = nil, bundleGroup: String? = nil, engines: [EngineFingerprint]? = nil,
        appCategories: [String]? = nil, appVersion: VersionRange? = nil, macOS: VersionRange? = nil,
        ax: AXMatch? = nil, web: WebMatch? = nil, titlePattern: String? = nil
    ) {
        self.bundleIds = bundleIds
        self.bundleGroup = bundleGroup
        self.engines = engines
        self.appCategories = appCategories
        self.appVersion = appVersion
        self.macOS = macOS
        self.ax = ax
        self.web = web
        self.titlePattern = titlePattern
    }
}

/// Any-of within a field, all-of across fields.
public struct AXMatch: Sendable, Hashable, Codable {
    public var roles: [String]?
    public var subroles: [String]?
    public var identifiers: [String]?
    public var domClasses: [String]?
    public var ancestorRoles: [String]?
    public var editable: Bool?

    public init(
        roles: [String]? = nil, subroles: [String]? = nil, identifiers: [String]? = nil,
        domClasses: [String]? = nil, ancestorRoles: [String]? = nil, editable: Bool? = nil
    ) {
        self.roles = roles
        self.subroles = subroles
        self.identifiers = identifiers
        self.domClasses = domClasses
        self.ancestorRoles = ancestorRoles
        self.editable = editable
    }
}

public struct WebMatch: Sendable, Hashable, Codable {
    /// Requires the AX document URL; evaluated in memory, never logged.
    public var urlPrefixes: [String]?

    public init(
        urlPrefixes: [String]? = nil
    ) {
        self.urlPrefixes = urlPrefixes
    }
}

public struct RuleAction: Sendable, Hashable, Codable {
    public var strategy: InjectionStrategy
    public var params: StrategyParams?
    /// Used only when the primary fails detectably (AX error, readback mismatch).
    public var fallback: [InjectionStrategy]?
    public var defaultMode: FirstSeenMode?
    public var requireTextFocus: RequireTextFocus?
    /// Not in the 5.4 field table but required by PLT-R342 ("the rule's verifyReentry"); defaults block has it.
    public var verifyReentry: VerifyReentry?
    public var axEnable: AXEnableMode?
    public var overlay: Bool?
    public var requiresUserOptIn: Bool?
    public var engineContext: EngineContextKind?
    public var features: RuleFeatures?

    public init(
        strategy: InjectionStrategy, params: StrategyParams? = nil, fallback: [InjectionStrategy]? = nil,
        defaultMode: FirstSeenMode? = nil, requireTextFocus: RequireTextFocus? = nil,
        verifyReentry: VerifyReentry? = nil, axEnable: AXEnableMode? = nil, overlay: Bool? = nil,
        requiresUserOptIn: Bool? = nil, engineContext: EngineContextKind? = nil, features: RuleFeatures? = nil
    ) {
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
    }
}

/// Keys from 02-platform.md section 4 plus the extra keys listed in 5.4 `action.params`.
public struct StrategyParams: Sendable, Hashable, Codable {
    public var unicodeChunk: Int?  // 1...20 (PLT-R404)
    public var interEventDelayUs: Int?  // 0...50,000 (PLT-R408)
    public var postDeleteSettleUs: Int?  // 0...50,000
    public var firstEditDelayUs: Int?  // 0...50,000
    public var inlineCompletion: InlineCompletionMode?
    public var allowMultiCharEvents: Bool?  // PLT-R480
    public var allowSplit: Bool?  // PLT-R408
    public var longTextThreshold: Int?  // graphemes, default 64 (PLT-R480)
    public var restoreDelayMs: Int?  // default 400 (PLT-R461)
    public var verifyAfterEdit: Bool?  // PLT-R410

    public init(
        unicodeChunk: Int? = nil, interEventDelayUs: Int? = nil, postDeleteSettleUs: Int? = nil,
        firstEditDelayUs: Int? = nil, inlineCompletion: InlineCompletionMode? = nil,
        allowMultiCharEvents: Bool? = nil, allowSplit: Bool? = nil, longTextThreshold: Int? = nil,
        restoreDelayMs: Int? = nil, verifyAfterEdit: Bool? = nil
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

/// `action.features` (all default true except `autoCapitalize`, a later feature).
public struct RuleFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool?
    public var macros: Bool?
    public var englishRestore: Bool?
    public var restoreHotkey: Bool?

    public init(
        autoCapitalize: Bool? = nil, macros: Bool? = nil, englishRestore: Bool? = nil, restoreHotkey: Bool? = nil
    ) {
        self.autoCapitalize = autoCapitalize
        self.macros = macros
        self.englishRestore = englishRestore
        self.restoreHotkey = restoreHotkey
    }
}

/// Shipped rules use the 5.4 provenance; user overrides use the PLT-R1205 suggestion shape. Decoded by the
/// presence of `source`.
public enum RuleProvenance: Sendable, Hashable, Codable {
    case shipped(Provenance)
    case userSuggestion(UserProvenance)

    public init(from decoder: any Decoder) throws { self = try Self.decodeTagged(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeTagged(to: encoder) }
}

public struct Provenance: Sendable, Hashable, Codable {
    public var reason: String
    public var evidence: [Evidence]
    public var tested: [TestedEntry]
    public var notes: String?
    public var addedIn: String
    public var reviewBy: String  // ISO date "YYYY-MM-DD"

    public init(
        reason: String, evidence: [Evidence], tested: [TestedEntry], notes: String? = nil, addedIn: String,
        reviewBy: String
    ) {
        self.reason = reason
        self.evidence = evidence
        self.tested = tested
        self.notes = notes
        self.addedIn = addedIn
        self.reviewBy = reviewBy
    }
}

public struct UserProvenance: Sendable, Hashable, Codable {
    public var source: String  // "user-suggestion"
    public var appVersion: String?
    public var macOS: String?
    public var date: String

    public init(
        source: String, appVersion: String? = nil, macOS: String? = nil, date: String
    ) {
        self.source = source
        self.appVersion = appVersion
        self.macOS = macOS
        self.date = date
    }
}

public struct Evidence: Sendable, Hashable, Codable {
    public var type: String  // "scenario", "issue", "report"
    public var ref: String

    public init(
        type: String, ref: String
    ) {
        self.type = type
        self.ref = ref
    }
}

public struct TestedEntry: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable { case pass, fail }
    public var app: String
    public var appVersion: String
    public var macOS: String
    public var date: String
    public var result: Result

    public init(
        app: String, appVersion: String, macOS: String, date: String, result: Result
    ) {
        self.app = app
        self.appVersion = appVersion
        self.macOS = macOS
        self.date = date
        self.result = result
    }
}

public struct RuleTest: Sendable, Hashable, Codable {
    public enum Automation: String, Sendable, Hashable, Codable { case automated, manual }
    /// Scenario ID (PLT-R530): `compat/scenarios/<scenario>.json` must exist.
    public var scenario: String
    public var automation: Automation

    public init(
        scenario: String, automation: Automation
    ) {
        self.scenario = scenario
        self.automation = automation
    }
}
