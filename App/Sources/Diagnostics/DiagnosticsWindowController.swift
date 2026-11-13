// SPDX-License-Identifier: GPL-3.0-or-later
//
// Diagnostics window (PLT-R1201), "This app misbehaves" flow (PLT-R1205), bug report sheet (PRD-R47-R49),
// typing trace review (PLT-R905) and latency probe window (PLT-R810). Workstream W2-C.

import AppKit
import AppModel
import Combine
import Diagnostics
import ShellCore
import SwiftUI

@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 620, height: 560)

    private let language: InterfaceLanguageModel
    private let services: DiagnosticsServices
    private let model: DiagnosticsWindowModel
    private var misbehaves: MisbehavesPanelController?
    private var bugReport: BugReportController?
    private var trace: TypingTraceCoordinator?
    private var probe: LatencyProbeWindowController?

    required init?(coder: NSCoder) { nil }

    /// `report` builds a fresh report (W2-A: `ReportAssembler.report` with the host's context). Without
    /// `services` only the report and its buttons work; each driver appears when its service is provided.
    init(
        language: InterfaceLanguageModel, report: @escaping @MainActor () -> DiagnosticsReport,
        services: DiagnosticsServices = DiagnosticsServices()
    ) {
        self.language = language
        self.services = services
        model = DiagnosticsWindowModel(language: language, services: services, report: report)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Diagnostics")
        window.contentViewController = NSHostingController(rootView: DiagnosticsWindowView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.perform = { [weak self] action in self?.perform(action) }
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.windowTitle) }
    }

    /// Opens the window with a freshly generated report (the text shown is the text copied, PLT-R1204). The
    /// report is built before this app activates, so the focus section names the field the user was in. `build`
    /// replaces the live report, for example with the bug report sheet's report of the same moment.
    func showReport(using build: (@MainActor () -> DiagnosticsReport)? = nil) {
        model.refresh(using: build)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    /// "Báo lỗi..." (PRD-R11 item 6, PRD-R47): the sheet with the Apps pane's apps and the last frontmost app
    /// chosen: `preselected` (the focused app when the menu item was chosen), or the most recent other app when that
    /// is this app or unknown. The host context is read now, before the sheet takes the focus.
    /// `symptom` is the one chosen in the misbehaves panel when the sheet continues from it (PRD-R49).
    func openBugReport(preselected: BundleKey?, symptom: DiagnosticsReport.Symptom = .other) {
        let apps = services.recentApps()
        let choice = RecentReportApps.preselection(
            focused: preselected, recent: apps, excluding: services.resolvedBrand.bundleIdentifier,
            name: services.appName)
        let draft = BugReportDraft(
            app: choice?.bundle, appName: choice?.name, symptom: symptom, userDescription: "",
            reproducesInPracticeField: nil)
        let build = reportBuilder()
        bugReport?.close()
        let controller = BugReportController(
            draft: draft, apps: apps, build: build, language: language, services: services)
        controller.openDiagnostics = { [weak self] in self?.showReport(using: { build(nil) }) }
        bugReport = controller
        controller.present()
    }

    /// The composition root's builder bound to the context of this moment; without it, the window's live report
    /// of this moment, which the sheet projects onto the draft (`BugReportSheet.report(from:)`).
    private func reportBuilder() -> DiagnosticsServices.ReportBuilder {
        if let session = services.reportSession { return session() }
        let base = model.freshReport()
        return { _ in base }
    }

    /// The app the window's report flows name while this window has the focus (PRD-R47 item 1).
    func lastFrontmostApp() -> BundleKey? { services.lastFrontmost(recent: services.recentApps())?.bundle }

    /// PLT-R1205 step 1: the user focused the problem field, then chose the menu item. The panel does not take
    /// focus away from that field; it reads the live focus snapshot, which belongs to `bundle` (the menu's
    /// frontmost app) unless focus moved since. Opened from the Diagnostics window the live focus is this app:
    /// the panel then names `bundle` in the report and asks the user to click into the problem field.
    func startMisbehavesFlow(for bundle: BundleKey?) {
        let controller = MisbehavesPanelController(
            language: language, services: services, bundle: bundle,
            report: { [weak self] in self?.model.currentReport() },
            openBugReport: { [weak self] app, symptom in self?.openBugReport(preselected: app, symptom: symptom) })
        misbehaves = controller
        controller.present()
    }

    func startTypingTrace() {
        guard let capture = services.trace else { return }
        let coordinator =
            trace
            ?? TypingTraceCoordinator(
                language: language, services: capture, appName: services.resolvedBrand.displayName)
        trace = coordinator
        coordinator.confirmAndStart(over: window)
    }

    func runLatencyProbe() {
        guard let latency = services.latency else { return }
        let controller =
            probe
            ?? LatencyProbeWindowController(
                language: language, services: latency, appName: services.resolvedBrand.displayName)
        probe = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    private func perform(_ action: DiagnosticsWindowAction) {
        switch action {
        case .copyReport: model.copyReport()
        case .misbehaves: startMisbehavesFlow(for: lastFrontmostApp())
        case .recordTrace: startTypingTrace()
        case .latencyTest: runLatencyProbe()
        case .openLogs: model.openLogs()
        }
    }
}

@MainActor
final class BugReportController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 560, height: 620)

    private let model: BugReportModel
    private let language: InterfaceLanguageModel
    private var practice: PracticeFieldWindowController?

    required init?(coder: NSCoder) { nil }

    /// Shows the exact redacted text before anything is copied or saved (PLT-R1204, PRD-R48). `apps` fill the
    /// picker (PRD-R47 item 1); `build` makes the report for each change of the draft.
    init(
        draft: BugReportDraft, apps: [BugReportAppChoice], build: @escaping DiagnosticsServices.ReportBuilder,
        language: InterfaceLanguageModel, services: DiagnosticsServices = DiagnosticsServices()
    ) {
        self.language = language
        model = BugReportModel(draft: draft, apps: apps, build: build, language: language, services: services)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BugReport")
        window.contentViewController = NSHostingController(rootView: BugReportView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.openPracticeField = { [weak self] in self?.showPracticeField() }
        model.window = { [weak self] in self?.window }
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.sheetTitle) }
    }

    /// "Mở cửa sổ chẩn đoán" (set by the composition root, which owns the Diagnostics window).
    var openDiagnostics: () -> Void {
        get { model.openDiagnostics }
        set { model.openDiagnostics = newValue }
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    private func showPracticeField() {
        let controller = practice ?? PracticeFieldWindowController(language: language)
        practice = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// Window titles follow a runtime language change (PRD-R63); SwiftUI content re-renders by itself.
@MainActor
enum WindowTitles {
    /// Unique address for the window's associated observation (never dereferenced).
    private static let observationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func follow(
        _ language: InterfaceLanguageModel, window: NSWindow, title: @escaping @MainActor (Localizer) -> String
    ) {
        window.title = title(language.localizer)
        let observation = language.afterChange { [weak window] in window?.title = title(language.localizer) }
        // The window owns its title observation, which ends when the window is deallocated (ADR 0315:
        // `withObservationTracking` needs macOS 14).
        objc_setAssociatedObject(window, observationKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
