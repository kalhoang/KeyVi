// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Bug report sheet logic (PRD-R47-R49, PLT-R1204, PLT-R1205) and report assembly (PLT-R1202).

public import AppModel
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
}

public enum BugReportComposer {
    /// GitHub issue-form URL with the summary in the body (the full block is copied to the clipboard after the
    /// sheet says so, PRD-R48). Repository URL is injected (VERIFY Pa's repository).
    public static func githubIssueURL(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        unimplemented()
    }

    /// Subject and body for the mail draft; the JSON report is attached by the App (PRD-R47).
    public static func mail(draft: BugReportDraft, report: DiagnosticsReport, localizer: Localizer)
        -> (subject: String, body: String)
    { unimplemented() }
}

/// Collects macOS version and build, architecture, model identifier (sysctl `hw.model`), languages.
public enum SystemInfoReader {
    public static func current(uiLanguage: InterfaceLanguage) -> SystemInfo { unimplemented() }
}
