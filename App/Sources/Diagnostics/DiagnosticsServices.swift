// SPDX-License-Identifier: LicenseRef-App-Pending
//
// What the composition root (W2-A) hands to the Diagnostics controllers, and the AppKit side effects of the
// report paths: clipboard (only after the PRD-R48 notice), save panel, mail draft with attachment, opening
// URLs and the logs folder.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import InputHost
import RealtimeSupport
import ShellCore

/// Services of the Diagnostics windows. Every member is optional: a missing service hides its feature.
@MainActor
struct DiagnosticsServices {
    var brand: Brand?
    /// The report for a bug report draft (W2-A: `ReportAssembler.report` with the host's current context).
    var reportForDraft: ((BugReportDraft?) -> DiagnosticsReport)?
    /// Recent apps for the sheet's picker, the last frontmost first (PRD-R47 item 1).
    var recentApps: () -> [BugReportAppChoice] = { [] }
    /// Focus snapshot of the field the user wants to test (PLT-R1205 step 1).
    var currentFocus: (() -> FocusSnapshot)?
    var guidedTest: GuidedTestServices?
    var trace: TypingTraceServices?
    var latency: LatencyProbeServices?
    /// `~/Library/Logs/<folder>/` (PLT-R903).
    var logsFolder: URL?
    /// "Use this for me now": stores the user override; it applies on the next keystroke (PLT-R540).
    var applyOverride: ((Rule) -> Void)?

    init(
        brand: Brand? = nil, reportForDraft: ((BugReportDraft?) -> DiagnosticsReport)? = nil,
        recentApps: @escaping () -> [BugReportAppChoice] = { [] }, currentFocus: (() -> FocusSnapshot)? = nil,
        guidedTest: GuidedTestServices? = nil, trace: TypingTraceServices? = nil, latency: LatencyProbeServices? = nil,
        logsFolder: URL? = nil, applyOverride: ((Rule) -> Void)? = nil
    ) {
        self.brand = brand
        self.reportForDraft = reportForDraft
        self.recentApps = recentApps
        self.currentFocus = currentFocus
        self.guidedTest = guidedTest
        self.trace = trace
        self.latency = latency
        self.logsFolder = logsFolder
        self.applyOverride = applyOverride
    }

    /// The bundle's brand when the composition root did not pass one.
    var resolvedBrand: Brand { brand ?? Brand.from(.main) }
}

/// PLT-R1205 step 3. The composition root provides this only when the host has a diagnostics pass-through;
/// without it the guided test is never offered (`MisbehavesTarget.offersGuidedTest`).
///
/// `setPassThrough(true)` must make the pipeline pass every keyboard event unchanged while the runner types:
/// the engine is not fed, no per-app memory or manual mode is written (English mode is not a substitute: it
/// records a manual switch and still runs macros), and the composition is reset on entry and exit (PLT-R210).
/// `setPassThrough(false)` restores the previous behaviour. Calls are balanced: one `false` follows every
/// `true`. Requested from W2-A as `InputHostController.setDiagnosticsPassThrough(_:)`, backed by a pause
/// reason such as `PauseCode.diagnosticsTest`.
@MainActor
struct GuidedTestServices {
    var runner: GuidedTestRunner
    var setPassThrough: (Bool) -> Void
    var macOSVersion: String
    /// Today as `YYYY-MM-DD` for the suggestion's provenance.
    var today: () -> String
    /// Bounded AX reads of the guided test's focus check, called on the typing thread (PLT-R342).
    var focusAX: any AXProvider = SystemAXProvider()
}

/// PLT-R905. `captureStateChanged` switches the menu-bar icon (W2-A: `StatusIconState` capturing).
@MainActor
struct TypingTraceServices {
    var capture: CaptureController
    var scheduler: any TimerScheduler
    var wallClock: any WallClock
    var captureStateChanged: (Bool) -> Void
}

/// PLT-R810. The driver shares the per-launch event marker with the pipeline; `onResult` keeps the result for
/// the next report (`ReportAssembler.report(probe:)`).
@MainActor
struct LatencyProbeServices {
    var driver: LatencyProbeDriver
    var metrics: PlatformMetrics
    var clock: any MonotonicClock
    var wallClock: any WallClock
    var layout: () -> LayoutTable?
    var method: () -> TypingMethod
    var onResult: (LatencyProbeResult) -> Void
}

/// AppKit side effects of the report flows.
@MainActor
enum ReportActions {
    /// PRD-R48: callers show the clipboard notice before this runs; the only intentional clipboard write.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func openFolder(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Save panel for the JSON report or an exported trace; `write` runs with the chosen URL.
    static func save(
        suggestedName: String, over window: NSWindow?, write: @escaping @MainActor (URL) -> Bool,
        done: @escaping @MainActor (Bool?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(nil) }
                done(write(url))
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    enum MailOutcome { case composed, fallbackWithoutAttachment, unavailable }

    /// "Gửi qua email" (PRD-R47): the system mail service with the JSON file attached; otherwise a `mailto:`
    /// draft without the attachment (the sheet then points to "Lưu tệp...").
    static func email(_ draft: MailDraft, attachment: Data) -> MailOutcome {
        if let service = NSSharingService(named: .composeEmail), let file = temporaryFile(attachment, draft) {
            service.recipients = draft.recipients
            service.subject = draft.subject
            let items: [Any] = [draft.body, file]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return .composed
            }
        }
        guard let url = BugReportComposer.mailtoURL(draft), NSWorkspace.shared.open(url) else { return .unavailable }
        return .fallbackWithoutAttachment
    }

    /// The attachment in a private temporary folder (0600): metadata only (PLT-R1203).
    private static func temporaryFile(_ data: Data, _ draft: MailDraft) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(draft.attachmentFileName)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
