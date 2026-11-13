// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Bug report sheet logic (PRD-R47-R49, PLT-R1204, PLT-R1205) and report assembly (PLT-R1202).

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import InputHost
public import SettingsStore

public struct BugReportDraft: Sendable, Hashable {
    public var app: BundleKey?
    public var appName: String?
    public var symptom: DiagnosticsReport.Symptom
    /// "Bạn gõ gì và mong ra gì?": typed by the user on purpose; goes only into the issue body or mail they
    /// send themselves, never into the diagnostics block.
    public var userDescription: String
    public var reproducesInPracticeField: Bool?

    public init(
        app: BundleKey?, appName: String?, symptom: DiagnosticsReport.Symptom, userDescription: String,
        reproducesInPracticeField: Bool?
    ) {
        self.app = app
        self.appName = appName
        self.symptom = symptom
        self.userDescription = userDescription
        self.reproducesInPracticeField = reproducesInPracticeField
    }
}

public enum ReportAssembler {
    /// Metadata only (PLT-R1202). The reported app is the draft's app, else the focused app; only its memory
    /// entry (PLT-R913) and its user override (PLT-R541, as a typed projection, ADR 0312) are included. The
    /// draft's free text never enters the report.
    public static func report(
        identity: AppIdentity, system: SystemInfo, host: HostReportContext, settings: SettingsState,
        metrics: MetricsSnapshot, health: [HealthEvent], probe: LatencyProbeResult?, draft: BugReportDraft?,
        now: Date
    ) -> DiagnosticsReport {
        let reportedApp = draft?.app ?? host.focus.app?.bundle
        let storedOverride = ReportedOverrideSource.override(for: reportedApp, in: settings.ruleOverrides)
        let decisionOverride = host.focus.app?.bundle == reportedApp ? host.decision?.userOverride : nil
        return DiagnosticsReport(
            generatedAt: now, app: identity, system: system, hostState: host.state.code,
            keyboard: ReportSections.keyboard(host), permissions: ReportSections.permissions(host),
            tap: ReportSections.tap(host, health: health, now: now), secureInput: ReportSections.secureInput(host),
            focus: ReportSections.focus(host),
            rule: ReportSections.rule(host.decision, userOverride: storedOverride ?? decisionOverride),
            settings: ReportSections.settings(settings),
            reportedAppMode: ReportSections.reportedAppMode(settings, reportedApp: reportedApp),
            latency: DiagnosticsReport.LatencySection(metrics: metrics, probe: probe),
            healthEvents: ReportSections.recentHealth(health), conflictingInputApps: ReportSections.conflicts(host),
            userReport: ReportSections.userReport(draft))
    }

    /// Typed projection of the reported app's user override (PLT-R541, ADR 0312): copies strategy, params,
    /// fallback, gating and metadata match fields; drops `summary`, `provenance`, `web.urlPrefixes` and
    /// `titlePattern` (listed by name in `omittedMatchFields`, values never copied, PLT-R1203).
    public static func reportedOverride(from rule: Rule) -> DiagnosticsReport.ReportedOverride {
        let match = rule.match
        let ax = match.ax
        var omitted: [DiagnosticsReport.OmittedMatchField] = []
        if match.web?.urlPrefixes != nil { omitted.append(.webURLPrefixes) }
        if match.titlePattern != nil { omitted.append(.titlePattern) }
        let reportedMatch = DiagnosticsReport.ReportedMatch(
            bundleIds: match.bundleIds, bundleGroup: match.bundleGroup, engines: match.engines,
            appCategories: match.appCategories, appVersion: match.appVersion, macOS: match.macOS, axRoles: ax?.roles,
            axSubroles: ax?.subroles, axIdentifiers: ax?.identifiers, axDomClasses: ax?.domClasses,
            axAncestorRoles: ax?.ancestorRoles, axEditable: ax?.editable)
        let action = rule.action
        return DiagnosticsReport.ReportedOverride(
            id: rule.id, match: reportedMatch, strategy: action.strategy,
            parameters: action.params.map(reportedParameters), fallback: action.fallback,
            requireTextFocus: action.requireTextFocus, verifyReentry: action.verifyReentry,
            engineContext: action.engineContext, omittedMatchFields: omitted)
    }

    private static func reportedParameters(_ params: StrategyParams) -> DiagnosticsReport.ReportedParameters {
        DiagnosticsReport.ReportedParameters(
            unicodeChunk: params.unicodeChunk, interEventDelayUs: params.interEventDelayUs,
            postDeleteSettleUs: params.postDeleteSettleUs, firstEditDelayUs: params.firstEditDelayUs,
            inlineCompletion: params.inlineCompletion, allowMultiCharEvents: params.allowMultiCharEvents,
            allowSplit: params.allowSplit, longTextThreshold: params.longTextThreshold,
            restoreDelayMs: params.restoreDelayMs, verifyAfterEdit: params.verifyAfterEdit)
    }
}

/// A mail draft for "Gửi qua email" (PRD-R47). The App sends it with
/// `NSSharingService(named: .composeEmail)`: `recipients`, `subject`, the body as the first item and the JSON
/// report file URL as an attachment. Only when no mail service is available does it fall back to a `mailto:`
/// URL with subject and body and no attachment (the sheet then offers "Lưu tệp..." for the JSON).
public struct MailDraft: Sendable, Hashable {
    public var recipients: [String]
    public var subject: String
    public var body: String
    /// Suggested file name of the attachment, `<slug>-report-YYYYMMDD-HHMM.json`.
    public var attachmentFileName: String

    public init(recipients: [String], subject: String, body: String, attachmentFileName: String) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentFileName = attachmentFileName
    }
}

/// The three ways out of the bug report sheet (PRD-R47, PRD-R49).
public enum BugReportPath: String, Sendable, Hashable, CaseIterable { case github, email, saveFile }

public enum BugReportComposer {
    /// Paths the sheet offers: GitHub only with a repository URL, email only with a support address; saving the
    /// file always works (PRD-R49: the flow works without a GitHub account).
    public static func availablePaths(brand: Brand) -> [BugReportPath] {
        BugReportPath.allCases.filter { path in
            switch path {
            case .github: brand.repositoryURL != nil
            case .email: brand.supportEmail != nil
            case .saveFile: true
            }
        }
    }

    /// GitHub issue-form URL with the summary in the body (the full block is copied to the clipboard after the
    /// sheet says so, PRD-R48). `repository` is `Brand.repositoryURL`; when it is nil the GitHub button is
    /// hidden and email/save remain (PRD-R49).
    public static func githubIssueURL(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        IssueFormURL.make(repository: repository, draft: draft, report: report)
    }

    /// Mail draft to `Brand.supportEmail` (nil when the brand has no support address).
    public static func mail(draft: BugReportDraft, report: DiagnosticsReport, brand: Brand, localizer: Localizer)
        -> MailDraft?
    {
        guard let address = brand.supportEmail else { return nil }
        let summary = BugReportSummary(draft: draft, report: report)
        let fileName = attachmentFileName(slug: brand.slug, date: report.generatedAt)
        return MailDraft(
            recipients: [address], subject: summary.mailSubject(localizer, appName: brand.displayName),
            body: summary.mailBody(localizer, appName: brand.displayName, attachment: fileName),
            attachmentFileName: fileName)
    }

    /// `mailto:` fallback (subject and body only; attachments are impossible with `mailto:`).
    public static func mailtoURL(_ draft: MailDraft) -> URL? {
        guard !draft.recipients.isEmpty else { return nil }
        let recipients = draft.recipients.map(URLQueryEncoding.encodeAddress).joined(separator: ",")
        let subject = URLQueryEncoding.encode(draft.subject)
        // RFC 6068: line breaks in the body are CRLF.
        let body = URLQueryEncoding.encode(draft.body.replacingOccurrences(of: "\n", with: "\r\n"))
        return URL(string: "mailto:\(recipients)?subject=\(subject)&body=\(body)")
    }

    /// `<slug>-report-YYYYMMDD-HHMM.json` in the user's time zone.
    static func attachmentFileName(slug: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0)
        return "\(slug)-report-\(stamp).json"
    }
}

/// Collects macOS version and build, architecture, model identifier (sysctl `hw.model`), languages.
public enum SystemInfoReader {
    public static func current(uiLanguage: InterfaceLanguage) -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(
            macOSVersion: versionString(version), macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            architecture: hardwareArchitecture(), modelIdentifier: sysctlString("hw.model") ?? "unknown",
            uiLanguage: uiLanguage, systemLanguage: Locale.preferredLanguages.first ?? "en")
    }

    static func versionString(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// Hardware class (PRD-R45): Apple silicon reports `arm64` even when the process runs translated.
    static func hardwareArchitecture() -> String {
        if sysctlInt("hw.optional.arm64") == 1 { return "arm64" }
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
