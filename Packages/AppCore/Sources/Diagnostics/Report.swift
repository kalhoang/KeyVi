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

    public init(
        formatVersion: Int = DiagnosticsReport.formatVersion, generatedAt: Date, app: AppIdentity, system: SystemInfo,
        hostState: HostStateCode, keyboard: KeyboardSection, permissions: PermissionsSection, tap: TapSection,
        secureInput: SecureInputSection, focus: FocusSection?, rule: RuleSection?, settings: SettingsSection,
        reportedAppMode: AppModeSection?, latency: LatencySection, healthEvents: [HealthEvent],
        conflictingInputApps: [BundleKey], userReport: UserReportSection?
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.app = app
        self.system = system
        self.hostState = hostState
        self.keyboard = keyboard
        self.permissions = permissions
        self.tap = tap
        self.secureInput = secureInput
        self.focus = focus
        self.rule = rule
        self.settings = settings
        self.reportedAppMode = reportedAppMode
        self.latency = latency
        self.healthEvents = healthEvents
        self.conflictingInputApps = conflictingInputApps
        self.userReport = userReport
    }

    public struct KeyboardSection: Sendable, Hashable, Codable {
        public var layout: InputSourceID?
        public var sourceKind: InputSourceKindCode
        public var enabledSources: [InputSourceID]

        public init(layout: InputSourceID?, sourceKind: InputSourceKindCode, enabledSources: [InputSourceID]) {
            self.layout = layout
            self.sourceKind = sourceKind
            self.enabledSources = enabledSources
        }
    }

    public enum InputSourceKindCode: String, Sendable, Hashable, Codable {
        case asciiLayout, nonLatinLayout, inputMethod, builtInVietnamese, unknown
    }

    public struct PermissionsSection: Sendable, Hashable, Codable {
        public var accessibility: PermissionState
        public var postEvent: PermissionState
        public var listenEvent: PermissionState
        public var health: PermissionHealthCode

        public init(
            accessibility: PermissionState, postEvent: PermissionState, listenEvent: PermissionState,
            health: PermissionHealthCode
        ) {
            self.accessibility = accessibility
            self.postEvent = postEvent
            self.listenEvent = listenEvent
            self.health = health
        }
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

        public init(
            enabled: Bool, location: String = "session", timeoutsLast24Hours: Int, userInputDisablesLast24Hours: Int,
            lastReenableReason: HealthEvent.Kind?
        ) {
            self.enabled = enabled
            self.location = location
            self.timeoutsLast24Hours = timeoutsLast24Hours
            self.userInputDisablesLast24Hours = userInputDisablesLast24Hours
            self.lastReenableReason = lastReenableReason
        }
    }

    public struct SecureInputSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var likelyHolder: BundleKey?
        public var holderKind: SecureInputHolder.Kind?

        public init(enabled: Bool, likelyHolder: BundleKey?, holderKind: SecureInputHolder.Kind?) {
            self.enabled = enabled
            self.likelyHolder = likelyHolder
            self.holderKind = holderKind
        }
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

        public init(
            bundle: BundleKey, appVersion: String?, engine: EngineFingerprint, axAvailability: AXAvailability,
            role: String?, subrole: String?, identifier: String?, domClasses: [String], editable: Bool?, secure: Bool
        ) {
            self.bundle = bundle
            self.appVersion = appVersion
            self.engine = engine
            self.axAvailability = axAvailability
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.domClasses = domClasses
            self.editable = editable
            self.secure = secure
        }
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

        public init(
            rule: RuleID?, source: DecisionSource, specificity: Int, strategy: InjectionStrategy,
            parameters: ReportedParameters, isUserOverride: Bool, userOverride: ReportedOverride?
        ) {
            self.rule = rule
            self.source = source
            self.specificity = specificity
            self.strategy = strategy
            self.parameters = parameters
            self.isUserOverride = isUserOverride
            self.userOverride = userOverride
        }
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

        public init(
            typingMethod: TypingMethod, tonePlacement: TonePlacement, englishRestore: Bool, standaloneW: Bool,
            bracketKeys: Bool, macrosEnabled: Bool, macroCount: Int, macrosInEnglishMode: Bool, rememberPerApp: Bool,
            toggleHotkey: HotkeyBinding, restoreHotkeySet: Bool, interfaceLanguage: InterfaceLanguage,
            updateChannel: UpdateChannel, explicitlySetKeys: [String]
        ) {
            self.typingMethod = typingMethod
            self.tonePlacement = tonePlacement
            self.englishRestore = englishRestore
            self.standaloneW = standaloneW
            self.bracketKeys = bracketKeys
            self.macrosEnabled = macrosEnabled
            self.macroCount = macroCount
            self.macrosInEnglishMode = macrosInEnglishMode
            self.rememberPerApp = rememberPerApp
            self.toggleHotkey = toggleHotkey
            self.restoreHotkeySet = restoreHotkeySet
            self.interfaceLanguage = interfaceLanguage
            self.updateChannel = updateChannel
            self.explicitlySetKeys = explicitlySetKeys
        }
    }

    public struct AppModeSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var rule: PerAppRule?
        public var rememberedMode: TypingMode?

        public init(bundle: BundleKey, rule: PerAppRule?, rememberedMode: TypingMode?) {
            self.bundle = bundle
            self.rule = rule
            self.rememberedMode = rememberedMode
        }
    }

    public struct LatencySection: Sendable, Hashable, Codable {
        public var metrics: MetricsSnapshot
        public var probe: LatencyProbeResult?

        public init(metrics: MetricsSnapshot, probe: LatencyProbeResult?) {
            self.metrics = metrics
            self.probe = probe
        }
    }

    public struct UserReportSection: Sendable, Hashable, Codable {
        public var symptom: Symptom
        public var reportedApp: BundleKey?
        public var reproducesInPracticeField: Bool?

        public init(symptom: Symptom, reportedApp: BundleKey?, reproducesInPracticeField: Bool?) {
            self.symptom = symptom
            self.reportedApp = reportedApp
            self.reproducesInPracticeField = reproducesInPracticeField
        }
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

        public init(
            profile: Profile, decideToPostedP50Microseconds: UInt64, decideToPostedP99Microseconds: UInt64,
            endToEndDeltaP50Microseconds: UInt64, endToEndDeltaP99Microseconds: UInt64, samples: Int
        ) {
            self.profile = profile
            self.decideToPostedP50Microseconds = decideToPostedP50Microseconds
            self.decideToPostedP99Microseconds = decideToPostedP99Microseconds
            self.endToEndDeltaP50Microseconds = endToEndDeltaP50Microseconds
            self.endToEndDeltaP99Microseconds = endToEndDeltaP99Microseconds
            self.samples = samples
        }
    }

    public var ranAt: Date
    public var results: [ProfileResult]

    public init(ranAt: Date, results: [ProfileResult]) {
        self.ranAt = ranAt
        self.results = results
    }
}

/// Renders a report for the three outputs of PLT-R1204/PRD-R47.
public enum DiagnosticsRenderer {
    /// Human-readable text in the interface language, shown verbatim before copying (PLT-R1204).
    public static func plainText(_ report: DiagnosticsReport, language: InterfaceLanguage) -> String {
        PlainTextReport(report: report, labels: ReportLabels.labels(for: language)).render()
    }

    /// QA-R44 block, parsed by the issue labeller (`scripts/parse-diagnostics.py`). The format is fixed by
    /// ADR 0501 (`docs/decisions/0501-diagnostics-block-format.md`). Exact shape:
    ///
    ///     ```text
    ///     <slug>-diagnostics v1
    ///     report.bundleId: com.example.App
    ///     app.version: 0.1.0
    ///     app.build: 12
    ///     app.channel: beta
    ///     macos.version: 27.1
    ///     macos.build: 26B123
    ///     hw.arch: arm64
    ///     input.method: telex
    ///     focus.bundleId: com.example.App
    ///     ...one `key: value` per line, keys from `DiagnosticsBlockKey` plus any ADR 0501 key...
    ///     ```
    ///
    /// `<slug>` is `report.app.slug` (read from the bundle, never hard-coded). Values never contain newlines;
    /// lists are comma-separated. Keys match `[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*`. At most 200 lines.
    public static func issueBlock(_ report: DiagnosticsReport) -> String { IssueBlock.render(report) }

    /// Inverse of `issueBlock` for tests and for the labeller contract: `nil` when no block or an unknown
    /// format version is found. Accepts any slug of the shape `[a-z][a-z0-9-]*` (ADR 0501 rule 1).
    public static func parseIssueBlock(_ text: String) -> [String: String]? { IssueBlock.parse(text) }

    /// JSON file attached by "Gửi qua email" / "Lưu tệp..." (PRD-R47): pretty-printed, sorted keys, ISO 8601
    /// dates. Decodes back into an equal `DiagnosticsReport`.
    public static func json(_ report: DiagnosticsReport) throws -> Data { try ReportJSON.encode(report) }

    /// The reported app's user override as rule JSON in the `compat/rules.json` shape (PLT-R541, ADR 0312), so
    /// a maintainer can paste it after adding `summary` and provenance. Content-bearing match fields are never
    /// part of `ReportedOverride`, so they cannot appear here.
    public static func ruleJSON(_ override: DiagnosticsReport.ReportedOverride, pretty: Bool) -> String {
        ReportJSON.rule(override, pretty: pretty)
    }
}

/// Keys of the issue block (ADR 0501). The labeller relies on `report.bundleId` / `focus.bundleId`,
/// `macos.version`, `hw.arch` and `input.method` (QA-R44 labels `app:<bundle>`, `macos:<major>`, `arch:...`,
/// `method:...`). Keys may be added within format v1; none of these may change or be removed.
public enum DiagnosticsBlockKey: String, Sendable, CaseIterable {
    case reportBundle = "report.bundleId"
    case reportAppVersion = "report.appVersion"
    case reportSymptom = "report.symptom"
    case appVersion = "app.version"
    case appBuild = "app.build"
    case appChannel = "app.channel"
    case macOSVersion = "macos.version"
    case macOSBuild = "macos.build"
    case architecture = "hw.arch"
    case model = "hw.model"
    case method = "input.method"
    case layout = "input.layout"
    case focusBundle = "focus.bundleId"
    case focusAppVersion = "focus.appVersion"
    case focusEngine = "focus.engine"
    case rule = "rule.id"
    case strategy = "rule.strategy"
    case secureInput = "secureInput.active"
    case hostState = "host.state"
}
