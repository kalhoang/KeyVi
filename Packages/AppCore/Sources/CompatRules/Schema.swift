// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public struct SecureInputHint: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    /// String Catalog key suffix, for example `terminal.secureKeyboardEntry` (PLT-R397, PLT-R398C).
    public var hintKey: String
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
}

/// Any-of within a field, all-of across fields.
public struct AXMatch: Sendable, Hashable, Codable {
    public var roles: [String]?
    public var subroles: [String]?
    public var identifiers: [String]?
    public var domClasses: [String]?
    public var ancestorRoles: [String]?
    public var editable: Bool?
}

public struct WebMatch: Sendable, Hashable, Codable {
    /// Requires the AX document URL; evaluated in memory, never logged.
    public var urlPrefixes: [String]?
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
}

/// Shipped rules use the 5.4 provenance; user overrides use the PLT-R1205 suggestion shape. Decoded by the
/// presence of `source`.
public enum RuleProvenance: Sendable, Hashable, Codable {
    case shipped(Provenance)
    case userSuggestion(UserProvenance)

    public init(from decoder: any Decoder) throws { unimplemented() }
    public func encode(to encoder: any Encoder) throws { unimplemented() }
}

public struct Provenance: Sendable, Hashable, Codable {
    public var reason: String
    public var evidence: [Evidence]
    public var tested: [TestedEntry]
    public var notes: String?
    public var addedIn: String
    public var reviewBy: String  // ISO date "YYYY-MM-DD"
}

public struct UserProvenance: Sendable, Hashable, Codable {
    public var source: String  // "user-suggestion"
    public var appVersion: String?
    public var macOS: String?
    public var date: String
}

public struct Evidence: Sendable, Hashable, Codable {
    public var type: String  // "scenario", "issue", "report"
    public var ref: String
}

public struct TestedEntry: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable { case pass, fail }
    public var app: String
    public var appVersion: String
    public var macOS: String
    public var date: String
    public var result: Result
}

public struct RuleTest: Sendable, Hashable, Codable {
    public enum Automation: String, Sendable, Hashable, Codable { case automated, manual }
    /// Scenario ID (PLT-R530): `compat/scenarios/<scenario>.json` must exist.
    public var scenario: String
    public var automation: Automation
}
