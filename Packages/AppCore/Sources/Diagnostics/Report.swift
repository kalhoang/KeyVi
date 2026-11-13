// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Environment report (PLT-R1202) and the machine-parseable issue block (QA-R44).
//
// Privacy is structural: the report type has no field that could hold typed text, field values, window
// titles, URLs, clipboard data, macro bodies or other apps' memory entries (PLT-R1203, PRD-R45). Adding such a
// field is a security review item (QA-R59).

public import AppModel
public import Foundation

public struct DiagnosticsReport: Sendable, Hashable, Codable {
    /// Bumped on any breaking change to the issue block keys (QA-R44).
    public static let formatVersion = 1

    public var formatVersion: Int
    public var generatedAt: Date
    public var app: AppIdentity
    public var system: SystemInfo
    public var hostState: HostStateCode
    public var keyboard: KeyboardSection
    public var permissions: PermissionsSection
    public var tap: TapSection
    public var secureInput: SecureInputSection
    public var focus: FocusSection?
    public var rule: RuleSection?
    public var settings: SettingsSection
    /// Per-app memory entry of the reported app only (PLT-R913).
    public var reportedAppMode: AppModeSection?
    public var latency: LatencySection
    /// Last 50 (PLT-R1202).
    public var healthEvents: [HealthEvent]
    public var conflictingInputApps: [BundleKey]
    public var userReport: UserReportSection?

    public struct KeyboardSection: Sendable, Hashable, Codable {
        public var layout: InputSourceID?
        public var sourceKind: InputSourceKindCode
        public var enabledSources: [InputSourceID]
    }

    public enum InputSourceKindCode: String, Sendable, Hashable, Codable {
        case asciiLayout, nonLatinLayout, inputMethod, builtInVietnamese, unknown
    }

    public struct PermissionsSection: Sendable, Hashable, Codable {
        public var accessibility: PermissionState
        public var postEvent: PermissionState
        public var listenEvent: PermissionState
        public var health: PermissionHealthCode
    }

    public enum PermissionHealthCode: String, Sendable, Hashable, Codable {
        case ready, noPermission, stale, secureInput, paused
    }

    public struct TapSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var location: String  // always "session" (PLT-R301)
        public var timeoutsLast24Hours: Int
        public var userInputDisablesLast24Hours: Int
        public var lastReenableReason: HealthEvent.Kind?
    }

    public struct SecureInputSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var likelyHolder: BundleKey?
        public var holderKind: SecureInputHolder.Kind?
    }

    public struct FocusSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var appVersion: String?
        public var engine: EngineFingerprint
        public var axAvailability: AXAvailability
        public var role: String?
        public var subrole: String?
        public var identifier: String?
        public var domClasses: [String]
        public var editable: Bool?
        public var secure: Bool
    }

    public struct RuleSection: Sendable, Hashable, Codable {
        public var rule: RuleID?
        public var source: DecisionSource
        public var specificity: Int
        public var strategy: InjectionStrategy
        /// Effective parameters after caps (every field set).
        public var parameters: ReportedParameters
        /// PLT-R1202 "override flag".
        public var isUserOverride: Bool
        /// The user override for the reported app, so maintainers can promote it (PLT-R541). A typed projection
        /// of the override rule: no free text, no URL, no title pattern (PLT-R1203, docs/decisions/0312).
        public var userOverride: ReportedOverride?
    }

    /// Strategy parameters as typed values (`StrategyParams` of the rules schema without its JSON form). In the
    /// effective `parameters` every field is set; in a `ReportedOverride` only the fields the override sets.
    public struct ReportedParameters: Sendable, Hashable, Codable {
        public var unicodeChunk: Int?
        public var interEventDelayUs: Int?
        public var postDeleteSettleUs: Int?
        public var firstEditDelayUs: Int?
        public var inlineCompletion: InlineCompletionMode?
        public var allowMultiCharEvents: Bool?
        public var allowSplit: Bool?
        public var longTextThreshold: Int?
        public var restoreDelayMs: Int?
        public var verifyAfterEdit: Bool?

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

    /// Typed projection of a user override rule (docs/decisions/0312-report-override-projection.md). Built by
    /// ShellCore's `ReportAssembler.reportedOverride(from:)`. Rendered as rule JSON in the report so a
    /// maintainer can paste it into `compat/rules.json` after adding provenance.
    public struct ReportedOverride: Sendable, Hashable, Codable {
        public var id: RuleID
        public var match: ReportedMatch
        public var strategy: InjectionStrategy
        public var parameters: ReportedParameters?
        public var fallback: [InjectionStrategy]?
        public var requireTextFocus: RequireTextFocus?
        public var verifyReentry: VerifyReentry?
        public var engineContext: EngineContextKind?
        /// Match fields present in the override but never reported because they can hold content
        /// (`web.urlPrefixes`, `titlePattern`): names only, never values (PLT-R1203).
        public var omittedMatchFields: [OmittedMatchField]

        public init(
            id: RuleID, match: ReportedMatch, strategy: InjectionStrategy, parameters: ReportedParameters?,
            fallback: [InjectionStrategy]?, requireTextFocus: RequireTextFocus?, verifyReentry: VerifyReentry?,
            engineContext: EngineContextKind?, omittedMatchFields: [OmittedMatchField]
        ) {
            self.id = id
            self.match = match
            self.strategy = strategy
            self.parameters = parameters
            self.fallback = fallback
            self.requireTextFocus = requireTextFocus
            self.verifyReentry = verifyReentry
            self.engineContext = engineContext
            self.omittedMatchFields = omittedMatchFields
        }
    }

    /// Match fields that are metadata (PLT-R1202 lists bundle ID, role, subrole, identifier, DOM classes; app
    /// categories, version ranges, engines and ancestor roles are metadata of the same kind).
    public struct ReportedMatch: Sendable, Hashable, Codable {
        public var bundleIds: [BundleKey]?
        public var bundleGroup: String?
        public var engines: [EngineFingerprint]?
        public var appCategories: [String]?
        public var appVersion: VersionRange?
        public var macOS: VersionRange?
        public var axRoles: [String]?
        public var axSubroles: [String]?
        public var axIdentifiers: [String]?
        public var axDomClasses: [String]?
        public var axAncestorRoles: [String]?
        public var axEditable: Bool?

        public init(
            bundleIds: [BundleKey]? = nil, bundleGroup: String? = nil, engines: [EngineFingerprint]? = nil,
            appCategories: [String]? = nil, appVersion: VersionRange? = nil, macOS: VersionRange? = nil,
            axRoles: [String]? = nil, axSubroles: [String]? = nil, axIdentifiers: [String]? = nil,
            axDomClasses: [String]? = nil, axAncestorRoles: [String]? = nil, axEditable: Bool? = nil
        ) {
            self.bundleIds = bundleIds
            self.bundleGroup = bundleGroup
            self.engines = engines
            self.appCategories = appCategories
            self.appVersion = appVersion
            self.macOS = macOS
            self.axRoles = axRoles
            self.axSubroles = axSubroles
            self.axIdentifiers = axIdentifiers
            self.axDomClasses = axDomClasses
            self.axAncestorRoles = axAncestorRoles
            self.axEditable = axEditable
        }
    }

    /// The two rule fields that can carry content (page addresses, window titles) and are therefore never
    /// copied into a report.
    public enum OmittedMatchField: String, Sendable, Hashable, Codable, CaseIterable {
        case webURLPrefixes = "web.urlPrefixes"
        case titlePattern
    }

    public struct SettingsSection: Sendable, Hashable, Codable {
        public var typingMethod: TypingMethod
        public var tonePlacement: TonePlacement
        public var englishRestore: Bool
        public var standaloneW: Bool
        public var bracketKeys: Bool
        public var macrosEnabled: Bool
        public var macroCount: Int  // count only (PRD-R33)
        public var macrosInEnglishMode: Bool
        public var rememberPerApp: Bool
        public var toggleHotkey: HotkeyBinding
        public var restoreHotkeySet: Bool
        public var interfaceLanguage: InterfaceLanguage
        public var updateChannel: UpdateChannel
        public var explicitlySetKeys: [String]  // names of keys the user changed (PRD-R6), no values
    }

    public struct AppModeSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var rule: PerAppRule?
        public var rememberedMode: TypingMode?
    }

    public struct LatencySection: Sendable, Hashable, Codable {
        public var metrics: MetricsSnapshot
        public var probe: LatencyProbeResult?
    }

    public struct UserReportSection: Sendable, Hashable, Codable {
        public var symptom: Symptom
        public var reportedApp: BundleKey?
        public var reproducesInPracticeField: Bool?
    }

    /// PRD-R47 chips and PLT-R1205 symptoms.
    public enum Symptom: String, Sendable, Hashable, Codable, CaseIterable {
        case lostLetters, duplicatedLetters, lettersOutOfOrder, wrongTone, cannotTypeVietnamese, nothingTyped,
            lag, other
    }
}

/// Result of the built-in latency probe (PLT-R810).
public struct LatencyProbeResult: Sendable, Hashable, Codable {
    public enum Profile: String, Sendable, Hashable, Codable, CaseIterable {
        case normal  // 120 ms between keys
        case fast  // 40 ms
        case burst  // 5 ms
    }

    public struct ProfileResult: Sendable, Hashable, Codable {
        public var profile: Profile
        public var decideToPostedP50Microseconds: UInt64
        public var decideToPostedP99Microseconds: UInt64
        public var endToEndDeltaP50Microseconds: UInt64
        public var endToEndDeltaP99Microseconds: UInt64
        public var samples: Int
    }

    public var ranAt: Date
    public var results: [ProfileResult]
}

/// Renders a report for the three outputs of PLT-R1204/PRD-R47.
public enum DiagnosticsRenderer {
    /// Human-readable text in the interface language, shown verbatim before copying (PLT-R1204).
    public static func plainText(_ report: DiagnosticsReport, language: InterfaceLanguage) -> String {
        unimplemented()
    }

    /// QA-R44 block, parsed by the issue labeller (CI track). Exact shape:
    ///
    ///     ```diagnostics
    ///     diagnostics-format: 1
    ///     app.version: 0.1.0
    ///     app.build: 12
    ///     app.channel: beta
    ///     macos.version: 27.1
    ///     macos.build: 26B123
    ///     arch: arm64
    ///     method: telex
    ///     focus.bundle: com.example.App
    ///     ...one `key: value` per line, keys from `DiagnosticsBlockKey`...
    ///     ```
    ///
    /// Values never contain newlines; lists are comma-separated. Keys are ASCII, lower camel case, dotted.
    public static func issueBlock(_ report: DiagnosticsReport) -> String { unimplemented() }

    /// Inverse of `issueBlock` for tests and for the labeller contract: `nil` when no block or an unknown
    /// format version is found.
    public static func parseIssueBlock(_ text: String) -> [String: String]? { unimplemented() }

    /// JSON file attached by "Gửi qua email" / "Lưu tệp..." (PRD-R47).
    public static func json(_ report: DiagnosticsReport) throws -> Data { unimplemented() }
}

/// Keys of the issue block that the labeller relies on (QA-R44 labels `app:<bundle>`, `macos:<major>`,
/// `arch:...`, `method:...`). Other keys may be added within a format version; these may not change.
public enum DiagnosticsBlockKey: String, Sendable, CaseIterable {
    case formatVersion = "diagnostics-format"
    case appVersion = "app.version"
    case appBuild = "app.build"
    case appChannel = "app.channel"
    case macOSVersion = "macos.version"
    case macOSBuild = "macos.build"
    case architecture = "arch"
    case method = "method"
    case focusBundle = "focus.bundle"
    case focusAppVersion = "focus.appVersion"
    case focusEngine = "focus.engine"
    case rule = "rule.id"
    case strategy = "rule.strategy"
    case hostState = "host.state"
    case secureInput = "secureInput.enabled"
    case layout = "keyboard.layout"
}
