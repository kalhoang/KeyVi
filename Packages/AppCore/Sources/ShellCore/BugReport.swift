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
}

public enum ReportAssembler {
    public static func report(
        identity: AppIdentity, system: SystemInfo, host: HostReportContext, settings: SettingsState,
        metrics: MetricsSnapshot, health: [HealthEvent], probe: LatencyProbeResult?, draft: BugReportDraft?,
        now: Date
    ) -> DiagnosticsReport { unimplemented() }

    /// Typed projection of the reported app's user override (PLT-R541, ADR 0312): copies strategy, params,
    /// fallback, gating and metadata match fields; drops `summary`, `provenance`, `web.urlPrefixes` and
    /// `titlePattern` (listed by name in `omittedMatchFields`, values never copied, PLT-R1203).
    public static func reportedOverride(from rule: Rule) -> DiagnosticsReport.ReportedOverride { unimplemented() }
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

public enum BugReportComposer {
    /// GitHub issue-form URL with the summary in the body (the full block is copied to the clipboard after the
    /// sheet says so, PRD-R48). `repository` is `Brand.repositoryURL`; when it is nil the GitHub button is
    /// hidden and email/save remain (PRD-R49).
    public static func githubIssueURL(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        unimplemented()
    }

    /// Mail draft to `Brand.supportEmail` (nil when the brand has no support address).
    public static func mail(draft: BugReportDraft, report: DiagnosticsReport, brand: Brand, localizer: Localizer)
        -> MailDraft?
    { unimplemented() }

    /// `mailto:` fallback (subject and body only; attachments are impossible with `mailto:`).
    public static func mailtoURL(_ draft: MailDraft) -> URL? { unimplemented() }
}

/// Collects macOS version and build, architecture, model identifier (sysctl `hw.model`), languages.
public enum SystemInfoReader {
    public static func current(uiLanguage: InterfaceLanguage) -> SystemInfo { unimplemented() }
}
