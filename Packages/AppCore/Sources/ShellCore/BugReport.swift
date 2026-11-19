// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// draft's free text never enters the report. `learnedCollisionEntries` is the collision memory's entry count
    /// (nil while it is not loaded): a count only, never a word (PLT-R901, PLT-R914).
    public static func report(
        identity: AppIdentity, system: SystemInfo, host: HostReportContext, settings: SettingsState,
        metrics: MetricsSnapshot, health: [HealthEvent], probe: LatencyProbeResult?, draft: BugReportDraft?,
        now: Date, learnedCollisionEntries: Int? = nil
    ) -> DiagnosticsReport {
        let reportedApp = draft?.app ?? host.focus.app?.bundle
        // PLT-R541, ADR 0312: for the focused app the override that decided, so `rule.id` and
        // `rule.userOverride` agree when the app has several; else the app's newest stored override.
        let decisionOverride = host.focus.app?.bundle == reportedApp ? host.decision?.userOverride : nil
        let storedOverride = ReportedOverrideSource.override(for: reportedApp, in: settings.ruleOverrides)
        return DiagnosticsReport(
            generatedAt: now, app: identity, system: system, hostState: host.state.code,
            keyboard: ReportSections.keyboard(host), permissions: ReportSections.permissions(host),
            tap: ReportSections.tap(host, health: health, now: now), secureInput: ReportSections.secureInput(host),
            focus: ReportSections.focus(host),
            rule: ReportSections.rule(host.decision, userOverride: decisionOverride ?? storedOverride),
            settings: ReportSections.settings(settings, learnedCollisionEntries: learnedCollisionEntries),
            reportedAppMode: ReportSections.reportedAppMode(settings, reportedApp: reportedApp),
            latency: DiagnosticsReport.LatencySection(metrics: metrics, probe: probe),
            healthEvents: ReportSections.recentHealth(health), conflictingInputApps: ReportSections.conflicts(host),
            userReport: ReportSections.userReport(draft), counters: ReportSections.counters(host))
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
/// URL with subject and body and no attachment (the sheet then offers "Lưu file..." for the JSON).
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

/// An app the user can pick in the sheet (PRD-R47 item 1): recent apps, the last frontmost one first.
public struct BugReportAppChoice: Sendable, Hashable {
    public var bundle: BundleKey
    public var name: String

    public init(bundle: BundleKey, name: String) {
        self.bundle = bundle
        self.name = name
    }
}

/// Buttons of the bug report sheet, in display order.
public enum BugReportAction: String, Sendable, Hashable, CaseIterable {
    /// Visible without opening the preview, so "Copy report" is the third click from the menu (section 12).
    case copyReport
    case github, email, saveFile
    /// PRD-R49 "test in the practice field".
    case practiceField
    case openDiagnostics

    /// The sheet control (label and VoiceOver hint keys) of this button (PRD-R66).
    public var control: DiagnosticsControl {
        switch self {
        case .copyReport: .copyReport
        case .github: .github
        case .email: .email
        case .saveFile: .saveFile
        case .practiceField: .practiceButton
        case .openDiagnostics: .openDiagnostics
        }
    }
}

/// PRD-R47-R49 sheet state without UI: the draft, the preview disclosure and the outputs of each path.
public struct BugReportSheet: Sendable, Hashable {
    public var apps: [BugReportAppChoice]
    public private(set) var draft: BugReportDraft
    public var previewExpanded = false
    /// Which output the preview shows (PLT-R1204); the copied block first, because "Copy report" is the
    /// shortest path (section 12).
    public var previewFormat: ReportPreviewFormat = .copiedBlock
    public let paths: [BugReportPath]

    /// `preselected` is the last frontmost app (PRD-R47 item 1); it is added to `apps` when missing.
    public init(apps: [BugReportAppChoice], preselected: BugReportAppChoice?, brand: Brand) {
        var list = apps
        if let preselected, !list.contains(where: { $0.bundle == preselected.bundle }) {
            list.insert(preselected, at: 0)
        }
        self.apps = list
        paths = BugReportComposer.availablePaths(brand: brand)
        draft = BugReportDraft(
            app: preselected?.bundle, appName: preselected?.name, symptom: .other, userDescription: "",
            reproducesInPracticeField: nil)
    }

    public var actions: [BugReportAction] {
        BugReportAction.allCases.filter { action in
            switch action {
            case .github: paths.contains(.github)
            case .email: paths.contains(.email)
            case .copyReport, .saveFile, .practiceField, .openDiagnostics: true
            }
        }
    }

    public mutating func selectApp(_ bundle: BundleKey?) {
        let choice = bundle.flatMap { key in apps.first { $0.bundle == key } }
        draft.app = choice?.bundle
        draft.appName = choice?.name
    }

    public mutating func select(_ symptom: DiagnosticsReport.Symptom) { draft.symptom = symptom }
    public mutating func setDescription(_ text: String) { draft.userDescription = text }
    public mutating func setReproducesInPracticeField(_ value: Bool?) { draft.reproducesInPracticeField = value }

    /// The report for this draft: the user's choices without the free text, and nothing about an app other
    /// than the selected one (PLT-R913, PLT-R541). Pass the report built for the draft when the App can rebuild
    /// it; otherwise sections of a previously reported app are dropped here.
    public func report(from base: DiagnosticsReport) -> DiagnosticsReport {
        var report = base
        report.userReport = ReportSections.userReport(draft)
        if report.reportedAppMode?.bundle != draft.app { report.reportedAppMode = nil }
        if let override = report.rule?.userOverride, !Self.matches(override, draft.app) {
            report.rule?.userOverride = nil
        }
        return report
    }

    private static func matches(_ override: DiagnosticsReport.ReportedOverride, _ app: BundleKey?) -> Bool {
        guard let app else { return false }
        return override.match.bundleIds?.contains(app) == true
    }

    /// PLT-R1204, PRD-R47 item 4: the preview shows exactly what the paths of `format` write.
    public func preview(_ report: DiagnosticsReport, format: ReportPreviewFormat) -> String { format.text(report) }

    /// The preview in the chosen `previewFormat`.
    public func preview(_ report: DiagnosticsReport) -> String { preview(report, format: previewFormat) }

    /// The block written to the clipboard by "Copy report" and "Mở GitHub" (QA-R44), after the notice (PRD-R48).
    public func clipboardText(_ report: DiagnosticsReport) -> String { ReportPreviewFormat.copiedBlock.text(report) }

    /// The JSON file for "Gửi qua email" and "Lưu file..." (PRD-R47).
    public func attachment(_ report: DiagnosticsReport) throws -> Data { try DiagnosticsRenderer.json(report) }

    public func attachmentFileName(slug: String, report: DiagnosticsReport) -> String {
        BugReportComposer.attachmentFileName(slug: slug, date: report.generatedAt)
    }

    public func githubURL(repository: URL, report: DiagnosticsReport) -> URL {
        BugReportComposer.githubIssueURL(repository: repository, draft: draft, report: report)
    }

    public func mail(report: DiagnosticsReport, brand: Brand, localizer: Localizer) -> MailDraft? {
        BugReportComposer.mail(draft: draft, report: report, brand: brand, localizer: localizer)
    }
}

/// Buttons of the Diagnostics window (PLT-R1201), in display order.
public enum DiagnosticsWindowAction: String, Sendable, Hashable, CaseIterable {
    case copyReport, misbehaves, recordTrace, latencyTest, openLogs
}

/// What the report menu items open (PRD-R11 items 4 and 6, PLT-R1205 step 1).
public enum DiagnosticsDestination: Sendable, Hashable {
    case bugReport(preselected: BundleKey?)
    case misbehaves(BundleKey)
    /// Crash-loop safe mode (PLT-R1009): the safe-mode choices (reset, use saved settings, report, later) come
    /// first, so reset and exit stay reachable whichever status line is showing.
    case safeModeChoices
}

/// Navigation from the menu to the report (02-platform.md section 12: a first-time user produces a report in
/// at most 3 clicks from the menu).
public enum DiagnosticsNavigation {
    public enum Click: Sendable, Hashable {
        case statusItem
        case menu(MenuEntry)
        case sheet(BugReportAction)
    }

    /// Where a report request comes from.
    public enum Origin: Sendable, Hashable {
        /// The status menu: PRD-R11 items 4 and 6 and the status line's "Báo lỗi...".
        case menu
        /// The Settings window: an Apps pane row or detail sheet (PRD-R37), the Support pane, a store notice.
        case settings
    }

    /// From the menu, "Báo lỗi..." opens the bug report sheet with the last frontmost app and "Báo lỗi với ứng
    /// dụng này..." opens the misbehaves flow for that app (the user focused the problem field first, PLT-R1205
    /// step 1; its panel continues to the sheet). In safe mode both open the safe-mode choices, whose "Report a
    /// Problem..." button continues to the report (PLT-R1009). From Settings the sheet opens pre-filled with the
    /// app (PRD-R37); Settings shows the safe-mode choices in its own notice.
    public static func destination(
        reportProblemFor bundle: BundleKey?, lastFrontmost: BundleKey?, safeMode: Bool = false,
        origin: Origin = .menu
    ) -> DiagnosticsDestination {
        guard origin == .menu else { return .bugReport(preselected: bundle ?? lastFrontmost) }
        if safeMode { return .safeModeChoices }
        if let bundle { return .misbehaves(bundle) }
        return .bugReport(preselected: lastFrontmost)
    }

    /// PLT-R1009: the shortest click path from the closed menu to the safe-mode choices. The status line's own
    /// action when the safe-mode line is showing, else the report item (a host-state line can outrank the
    /// safe-mode line). Nil outside safe mode or when the menu offers neither.
    public static func pathToSafeModeChoices(menu: MenuModel, safeMode: Bool) -> [Click]? {
        guard safeMode else { return nil }
        if let line = menu.statusLine, line.action == .safeModeChoices, menu.entries.contains(.statusAction(line)) {
            return [.statusItem, .menu(.statusAction(line))]
        }
        guard menu.entries.contains(.reportProblem),
            destination(reportProblemFor: nil, lastFrontmost: nil, safeMode: true) == .safeModeChoices
        else { return nil }
        return [.statusItem, .menu(.reportProblem)]
    }

    /// The shortest click path from the closed menu to "Copy report": open the menu, choose "Báo lỗi...", press
    /// "Copy report" in the sheet. Nil when the menu or the sheet do not offer the step.
    public static func pathToCopyReport(menu: MenuModel, sheet: BugReportSheet) -> [Click]? {
        guard menu.entries.contains(.reportProblem), sheet.actions.contains(.copyReport) else { return nil }
        guard case .bugReport = destination(reportProblemFor: nil, lastFrontmost: menu.frontmostApp?.bundle) else {
            return nil
        }
        return [.statusItem, .menu(.reportProblem), .sheet(.copyReport)]
    }
}
