// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Builds `DiagnosticsReport` values for `ReportAssembler` (PLT-R1202, PLT-R1203, PLT-R913).
//
// `DiagnosticsReport` and its sections live in Diagnostics (W1-A) and have no public memberwise initializers, so
// ShellCore fills a field-for-field mirror and decodes the report from it through the report's own `Codable`
// conformance. The mirror holds only the report's own field types: it cannot add a field the report does not
// have, and a drift between the two fails `ReportAssemblerTests` on the first run. When Diagnostics gains public
// initializers (cross-track request), `ReportMirror.decode()` collapses to direct construction.

internal import AppModel
internal import CompatRules
internal import Diagnostics
internal import Foundation
internal import InputHost
internal import SettingsStore

struct ReportMirror: Encodable {
    typealias Report = DiagnosticsReport

    var formatVersion: Int
    var generatedAt: Date
    var app: AppIdentity
    var system: SystemInfo
    var hostState: HostStateCode
    var keyboard: Keyboard
    var permissions: Permissions
    var tap: Tap
    var secureInput: SecureInput
    var focus: Focus?
    var rule: RuleMirror?
    var settings: Settings
    var reportedAppMode: AppMode?
    var latency: Latency
    var healthEvents: [HealthEvent]
    var conflictingInputApps: [BundleKey]
    var userReport: UserReport?

    struct Keyboard: Encodable {
        var layout: InputSourceID?
        var sourceKind: Report.InputSourceKindCode
        var enabledSources: [InputSourceID]
    }

    struct Permissions: Encodable {
        var accessibility: PermissionState
        var postEvent: PermissionState
        var listenEvent: PermissionState
        var health: Report.PermissionHealthCode
    }

    struct Tap: Encodable {
        var enabled: Bool
        var location: String
        var timeoutsLast24Hours: Int
        var userInputDisablesLast24Hours: Int
        var lastReenableReason: HealthEvent.Kind?
    }

    struct SecureInput: Encodable {
        var enabled: Bool
        var likelyHolder: BundleKey?
        var holderKind: SecureInputHolder.Kind?
    }

    struct Focus: Encodable {
        var bundle: BundleKey
        var appVersion: String?
        var engine: EngineFingerprint
        var axAvailability: AXAvailability
        var role: String?
        var subrole: String?
        var identifier: String?
        var domClasses: [String]
        var editable: Bool?
        var secure: Bool
    }

    struct RuleMirror: Encodable {
        var rule: RuleID?
        var source: DecisionSource
        var specificity: Int
        var strategy: InjectionStrategy
        var parameters: Report.ReportedParameters
        var isUserOverride: Bool
        var userOverride: Report.ReportedOverride?
    }

    struct Settings: Encodable {
        var typingMethod: TypingMethod
        var tonePlacement: TonePlacement
        var englishRestore: Bool
        var standaloneW: Bool
        var bracketKeys: Bool
        var macrosEnabled: Bool
        var macroCount: Int
        var macrosInEnglishMode: Bool
        var rememberPerApp: Bool
        var toggleHotkey: HotkeyBinding
        var restoreHotkeySet: Bool
        var interfaceLanguage: InterfaceLanguage
        var updateChannel: UpdateChannel
        var explicitlySetKeys: [String]
    }

    struct AppMode: Encodable {
        var bundle: BundleKey
        var rule: PerAppRule?
        var rememberedMode: TypingMode?
    }

    struct Latency: Encodable {
        var metrics: MetricsSnapshot
        var probe: LatencyProbeResult?
    }

    struct UserReport: Encodable {
        var symptom: Report.Symptom
        var reportedApp: BundleKey?
        var reproducesInPracticeField: Bool?
    }

    /// The report with exactly these values. A failure means the mirror no longer matches `DiagnosticsReport`,
    /// a build defect that the report tests catch, never a runtime condition.
    func decode() -> DiagnosticsReport {
        do {
            let data = try JSONEncoder().encode(self)
            return try JSONDecoder().decode(DiagnosticsReport.self, from: data)
        } catch {
            preconditionFailure("ReportMirror does not match DiagnosticsReport: \(error)")
        }
    }
}

/// Section builders, one per PLT-R1202 group.
enum ReportSections {
    static let healthEventLimit = 50  // PLT-R1202 "last 50 health events"
    static let window: TimeInterval = 24 * 60 * 60

    static func keyboard(_ host: HostReportContext) -> ReportMirror.Keyboard {
        let source = host.inputSource.source
        let kind: DiagnosticsReport.InputSourceKindCode =
            if source.isBuiltInVietnamese {
                .builtInVietnamese
            } else {
                switch source.kind {
                case .asciiLayout: .asciiLayout
                case .nonASCIILayout: .nonLatinLayout
                case .inputMethod, .inputMode: .inputMethod
                }
            }
        // PLT-R362: layout identifier; source names are never copied (they are display strings).
        return ReportMirror.Keyboard(layout: source.id, sourceKind: kind, enabledSources: host.enabledSources.map(\.id))
    }

    static func permissions(_ host: HostReportContext) -> ReportMirror.Permissions {
        let status = host.permissions
        let health: DiagnosticsReport.PermissionHealthCode =
            switch (status.health, host.state) {
            case (.stale, _): .stale
            case (.noPermission, _): .noPermission
            case (.ready, .paused(.secureInput)): .secureInput
            case (.ready, .paused): .paused
            case (.ready, _): .ready
            }
        return ReportMirror.Permissions(
            accessibility: status.accessibility, postEvent: status.postEvent, listenEvent: status.listenEvent,
            health: health)
    }

    static func tap(_ host: HostReportContext, health: [HealthEvent], now: Date) -> ReportMirror.Tap {
        let recent = health.filter { $0.at > now.addingTimeInterval(-window) && $0.at <= now }
        let disables = health.filter { $0.kind == .tapTimeout || $0.kind == .tapDisabledByUserInput }
        return ReportMirror.Tap(
            enabled: host.tapEnabled, location: "session",  // PLT-R301: always the session tap
            timeoutsLast24Hours: recent.count { $0.kind == .tapTimeout },
            userInputDisablesLast24Hours: recent.count { $0.kind == .tapDisabledByUserInput },
            lastReenableReason: disables.max { $0.at < $1.at }?.kind)
    }

    static func secureInput(_ host: HostReportContext) -> ReportMirror.SecureInput {
        // Holder bundle ID and kind only; the display name is never reported.
        ReportMirror.SecureInput(
            enabled: host.secureInput.enabled, likelyHolder: host.secureInput.holder?.bundle,
            holderKind: host.secureInput.holder?.kind)
    }

    static func focus(_ host: HostReportContext) -> ReportMirror.Focus? {
        guard let app = host.focus.app else { return nil }
        let field = host.focus.field
        return ReportMirror.Focus(
            bundle: app.bundle, appVersion: app.appVersion?.original, engine: app.engine,
            axAvailability: field.axAvailability, role: field.role, subrole: field.subrole,
            identifier: field.identifier, domClasses: field.domClasses, editable: field.editable, secure: field.secure)
    }

    static func rule(_ decision: ResolvedDecision?, userOverride: Rule?) -> ReportMirror.RuleMirror? {
        guard let decision else { return nil }
        let params = decision.params
        let parameters = DiagnosticsReport.ReportedParameters(
            unicodeChunk: params.unicodeChunk, interEventDelayUs: params.interEventDelayUs,
            postDeleteSettleUs: params.postDeleteSettleUs, firstEditDelayUs: params.firstEditDelayUs,
            inlineCompletion: params.inlineCompletion, allowMultiCharEvents: params.allowMultiCharEvents,
            allowSplit: params.allowSplit, longTextThreshold: params.longTextThreshold,
            restoreDelayMs: params.restoreDelayMs, verifyAfterEdit: params.verifyAfterEdit)
        return ReportMirror.RuleMirror(
            rule: decision.rule, source: decision.source, specificity: decision.specificity,
            strategy: decision.strategy, parameters: parameters, isUserOverride: decision.source == .user,
            userOverride: userOverride.map(ReportAssembler.reportedOverride(from:)))
    }

    static func settings(_ state: SettingsState) -> ReportMirror.Settings {
        let effective = state.effective
        return ReportMirror.Settings(
            typingMethod: effective.typingMethod, tonePlacement: effective.tonePlacement,
            englishRestore: effective.englishRestore, standaloneW: effective.telexStandaloneW,
            bracketKeys: effective.telexBracketKeys, macrosEnabled: effective.macrosEnabled,
            macroCount: state.macros.count,  // PRD-R33: count only
            macrosInEnglishMode: effective.macrosInEnglishMode, rememberPerApp: effective.rememberPerApp,
            toggleHotkey: effective.toggleHotkey, restoreHotkeySet: effective.restoreHotkey != nil,
            interfaceLanguage: effective.interfaceLanguage, updateChannel: effective.updateChannel,
            explicitlySetKeys: ExplicitSettingKeys.names(state.user))
    }

    /// PLT-R913: the memory entry of the reported app only.
    static func reportedAppMode(_ state: SettingsState, reportedApp: BundleKey?) -> ReportMirror.AppMode? {
        guard let reportedApp, let entry = state.appModes.apps.first(where: { $0.bundle == reportedApp }) else {
            return nil
        }
        return ReportMirror.AppMode(bundle: entry.bundle, rule: entry.rule, rememberedMode: entry.mode)
    }

    static func recentHealth(_ health: [HealthEvent]) -> [HealthEvent] {
        Array(health.sorted { $0.at < $1.at }.suffix(healthEventLimit))
    }

    static func conflicts(_ host: HostReportContext) -> [BundleKey] {
        host.conflicts.compactMap { conflict in
            if case .runningApp(let bundle, _) = conflict { return bundle }
            return nil
        }
    }
}

/// Names of explicitly set settings keys, no values (PRD-R6, PLT-R1202). Mirrors the JSON key names documented in
/// `UserSettings`; W1-B's `UserSettings.explicitlySetKeys` replaces it once implemented (cross-track request).
enum ExplicitSettingKeys {
    static func names(_ user: UserSettings) -> [String] {
        let flags: [(String, Bool)] = [
            ("typingMethod", user.typingMethod.isSet), ("tonePlacement", user.tonePlacement.isSet),
            ("englishRestore", user.englishRestore.isSet), ("telexStandaloneW", user.telexStandaloneW.isSet),
            ("telexBracketKeys", user.telexBracketKeys.isSet), ("restoreHotkey", user.restoreHotkey.isSet),
            ("macrosEnabled", user.macrosEnabled.isSet), ("macrosInEnglishMode", user.macrosInEnglishMode.isSet),
            ("toggleHotkey", user.toggleHotkey.isSet), ("rememberPerApp", user.rememberPerApp.isSet),
            ("firstSeenAppMode", user.firstSeenAppMode.isSet), ("showSwitchIndicator", user.showSwitchIndicator.isSet),
            ("soundOnSwitch", user.soundOnSwitch.isSet), ("clickIconToToggle", user.clickIconToToggle.isSet),
            ("interfaceLanguage", user.interfaceLanguage.isSet),
            ("automaticallyCheckForUpdates", user.automaticallyCheckForUpdates.isSet),
            ("automaticallyInstallUpdates", user.automaticallyInstallUpdates.isSet),
            ("updateChannel", user.updateChannel.isSet), ("layoutBinding", user.layoutBinding.isSet),
        ]
        return flags.filter(\.1).map(\.0)
    }
}

/// The reported app's user override from `rule-overrides.json` (PLT-R541), newest first.
enum ReportedOverrideSource {
    static func override(for app: BundleKey?, in stored: [StoredRuleOverride]) -> Rule? {
        guard let app else { return nil }
        let rules = stored.sorted { $0.createdAt > $1.createdAt }.compactMap { decode($0.rule) }
        return rules.first { $0.match.bundleIds?.contains(app) == true }
    }

    /// Decodes the raw rule JSON without `provenance` and `test`, which are never reported and whose shapes are
    /// validated by CompatRules, not here.
    static func decode(_ raw: JSONValue) -> Rule? {
        guard var object = raw.objectValue else { return nil }
        object["provenance"] = nil
        object["test"] = nil
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return nil }
        return try? JSONDecoder().decode(Rule.self, from: data)
    }
}
