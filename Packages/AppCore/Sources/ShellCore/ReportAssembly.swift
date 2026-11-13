// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Section builders for `ReportAssembler` (PLT-R1202, PLT-R1203, PLT-R913). Each builder fills one
// `DiagnosticsReport` section through the public memberwise initialisers of Diagnostics, so a new field in a
// section is a compile error here rather than a silently missing value.

internal import AppModel
internal import CompatRules
internal import Diagnostics
internal import Foundation
internal import InputHost
internal import SettingsStore

/// Section builders, one per PLT-R1202 group.
enum ReportSections {
    static let healthEventLimit = 50  // PLT-R1202 "last 50 health events"
    static let window: TimeInterval = 24 * 60 * 60

    static func keyboard(_ host: HostReportContext) -> DiagnosticsReport.KeyboardSection {
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
        return DiagnosticsReport.KeyboardSection(
            layout: source.id, sourceKind: kind, enabledSources: host.enabledSources.map(\.id))
    }

    static func permissions(_ host: HostReportContext) -> DiagnosticsReport.PermissionsSection {
        let status = host.permissions
        let health: DiagnosticsReport.PermissionHealthCode =
            switch (status.health, host.state) {
            case (.stale, _): .stale
            case (.noPermission, _): .noPermission
            case (.ready, .paused(.secureInput)): .secureInput
            case (.ready, .paused): .paused
            case (.ready, _): .ready
            }
        return DiagnosticsReport.PermissionsSection(
            accessibility: status.accessibility, postEvent: status.postEvent, listenEvent: status.listenEvent,
            health: health)
    }

    static func tap(_ host: HostReportContext, health: [HealthEvent], now: Date) -> DiagnosticsReport.TapSection {
        let recent = health.filter { $0.at > now.addingTimeInterval(-window) && $0.at <= now }
        let disables = health.filter { $0.kind == .tapTimeout || $0.kind == .tapDisabledByUserInput }
        // PLT-R301: the location is always the session tap (the initialiser's default).
        return DiagnosticsReport.TapSection(
            enabled: host.tapEnabled, timeoutsLast24Hours: recent.count { $0.kind == .tapTimeout },
            userInputDisablesLast24Hours: recent.count { $0.kind == .tapDisabledByUserInput },
            lastReenableReason: disables.max { $0.at < $1.at }?.kind)
    }

    static func secureInput(_ host: HostReportContext) -> DiagnosticsReport.SecureInputSection {
        // Holder bundle ID and kind only; the display name is never reported.
        DiagnosticsReport.SecureInputSection(
            enabled: host.secureInput.enabled, likelyHolder: host.secureInput.holder?.bundle,
            holderKind: host.secureInput.holder?.kind)
    }

    static func focus(_ host: HostReportContext) -> DiagnosticsReport.FocusSection? {
        guard let app = host.focus.app else { return nil }
        let field = host.focus.field
        return DiagnosticsReport.FocusSection(
            bundle: app.bundle, appVersion: app.appVersion?.original, engine: app.engine,
            axAvailability: field.axAvailability, role: field.role, subrole: field.subrole,
            identifier: field.identifier, domClasses: field.domClasses, editable: field.editable, secure: field.secure)
    }

    static func rule(_ decision: ResolvedDecision?, userOverride: Rule?) -> DiagnosticsReport.RuleSection? {
        guard let decision else { return nil }
        let params = decision.params
        let parameters = DiagnosticsReport.ReportedParameters(
            unicodeChunk: params.unicodeChunk, interEventDelayUs: params.interEventDelayUs,
            postDeleteSettleUs: params.postDeleteSettleUs, firstEditDelayUs: params.firstEditDelayUs,
            inlineCompletion: params.inlineCompletion, allowMultiCharEvents: params.allowMultiCharEvents,
            allowSplit: params.allowSplit, longTextThreshold: params.longTextThreshold,
            restoreDelayMs: params.restoreDelayMs, verifyAfterEdit: params.verifyAfterEdit)
        return DiagnosticsReport.RuleSection(
            rule: decision.rule, source: decision.source, specificity: decision.specificity,
            strategy: decision.strategy, parameters: parameters, isUserOverride: decision.source == .user,
            userOverride: userOverride.map(ReportAssembler.reportedOverride(from:)))
    }

    static func settings(_ state: SettingsState) -> DiagnosticsReport.SettingsSection {
        let effective = state.effective
        return DiagnosticsReport.SettingsSection(
            typingMethod: effective.typingMethod, tonePlacement: effective.tonePlacement,
            englishRestore: effective.englishRestore, standaloneW: effective.telexStandaloneW,
            bracketKeys: effective.telexBracketKeys, macrosEnabled: effective.macrosEnabled,
            macroCount: state.macros.count,  // PRD-R33: count only
            macrosInEnglishMode: effective.macrosInEnglishMode, rememberPerApp: effective.rememberPerApp,
            toggleHotkey: effective.toggleHotkey, restoreHotkeySet: effective.restoreHotkey != nil,
            interfaceLanguage: effective.interfaceLanguage, updateChannel: effective.updateChannel,
            // PRD-R6: names of explicitly set keys, never values (SettingsStore owns the names).
            explicitlySetKeys: state.user.explicitlySetKeys)
    }

    /// PLT-R913: the memory entry of the reported app only.
    static func reportedAppMode(_ state: SettingsState, reportedApp: BundleKey?) -> DiagnosticsReport.AppModeSection? {
        guard let reportedApp, let entry = state.appModes.apps.first(where: { $0.bundle == reportedApp }) else {
            return nil
        }
        return DiagnosticsReport.AppModeSection(bundle: entry.bundle, rule: entry.rule, rememberedMode: entry.mode)
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

    /// The draft's choices without its free text (PRD-R47 item 3 stays in the issue body or mail only).
    static func userReport(_ draft: BugReportDraft?) -> DiagnosticsReport.UserReportSection? {
        draft.map {
            DiagnosticsReport.UserReportSection(
                symptom: $0.symptom, reportedApp: $0.app, reproducesInPracticeField: $0.reproducesInPracticeField)
        }
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
