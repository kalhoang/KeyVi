// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics window (PLT-R1201), "This app misbehaves" flow (PLT-R1205), bug report sheet (PRD-R47-R49),
// typing trace review (PLT-R905) and latency probe window (PLT-R810). Workstream W2-C.

import AppKit
import AppModel
import Diagnostics
import Observation
import ShellCore
import SwiftUI

@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 620, height: 560)

    private let language: InterfaceLanguageModel
    private let services: DiagnosticsServices
    private let model: DiagnosticsWindowModel
    private var misbehaves: MisbehavesPanelController?
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

    /// Opens the window with a freshly generated report (the text shown is the text copied, PLT-R1204).
    func showReport() {
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// PLT-R1205 step 1: the user focused the problem field, then chose the menu item. The panel does not take
    /// focus away from that field; it reads the live focus snapshot, which belongs to `bundle` (the menu's
    /// frontmost app) unless focus moved since.
    func startMisbehavesFlow(for bundle: BundleKey?) {
        let controller = MisbehavesPanelController(
            language: language, services: services, report: { [weak self] in self?.model.currentReport() })
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
        NSApp.activate()
    }

    private func perform(_ action: DiagnosticsWindowAction) {
        switch action {
        case .copyReport: model.copyReport()
        case .misbehaves: startMisbehavesFlow(for: services.currentFocus?().app?.bundle)
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

    /// Shows the exact redacted text before anything is copied or saved (PLT-R1204, PRD-R48).
    init(
        draft: BugReportDraft, report: DiagnosticsReport, language: InterfaceLanguageModel,
        services: DiagnosticsServices = DiagnosticsServices()
    ) {
        self.language = language
        model = BugReportModel(draft: draft, report: report, language: language, services: services)
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
        NSApp.activate()
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
    static func follow(
        _ language: InterfaceLanguageModel, window: NSWindow, title: @escaping @MainActor (Localizer) -> String
    ) {
        window.title = title(language.localizer)
        withObservationTracking {
            _ = language.localizer
        } onChange: { [weak window] in
            Task { @MainActor [weak window] in
                guard let window else { return }
                follow(language, window: window, title: title)
            }
        }
    }
}
