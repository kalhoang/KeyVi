// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Run typing latency test" window (PLT-R810): a plain text view that receives the probe's keys and reports
// every text change to the driver, a start button, progress per profile and the T2 and T4 result lines. The
// result is handed to the composition root for the next diagnostics report.

import AppKit
import AppModel
import Diagnostics
import InputHost
import Observation
import RealtimeSupport
import ShellCore
import SwiftUI

@MainActor
final class LatencyProbeWindowController: NSWindowController {
    private let model: LatencyProbeModel

    required init?(coder: NSCoder) { nil }

    init(language: InterfaceLanguageModel, services: LatencyProbeServices, appName: String) {
        model = LatencyProbeModel(language: language, services: services, appName: appName)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LatencyProbe")
        window.contentViewController = NSHostingController(rootView: LatencyProbeView(model: model))
        window.center()
        super.init(window: window)
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.probeTitle) }
    }
}

@MainActor
@Observable
final class LatencyProbeModel {
    enum Phase: Equatable {
        case idle
        case running(LatencyProbeResult.Profile)
        case done(LatencyProbeResult)
        case unavailable
    }

    let language: InterfaceLanguageModel
    let appName: String
    @ObservationIgnored let services: LatencyProbeServices
    private(set) var phase: Phase = .idle
    /// Bumped before each run so the text view clears its content.
    private(set) var runID = 0

    init(language: InterfaceLanguageModel, services: LatencyProbeServices, appName: String) {
        self.language = language
        self.services = services
        self.appName = appName
    }

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func start() {
        guard !isRunning else { return }
        guard let layout = services.layout(),
            let script = LatencyProbeScript.standard(layout: layout, method: services.method())
        else {
            phase = .unavailable
            return
        }
        runID += 1
        let session = LatencyProbeSession(
            driver: services.driver, metrics: services.metrics, wallClock: services.wallClock)
        let show: @MainActor @Sendable (LatencyProbeResult.Profile) -> Void = { [weak self] profile in
            self?.phase = .running(profile)
        }
        Task { [weak self] in
            let result = await session.run(script: script) { profile in Task { await show(profile) } }
            self?.finish(result)
        }
    }

    private func finish(_ result: LatencyProbeResult) {
        phase = .done(result)
        services.onResult(result)
    }

    /// Main thread, from the text view's change notification.
    func textChanged() { services.driver.textChanged(at: services.clock.now()) }
}

struct LatencyProbeView: View {
    let model: LatencyProbeModel

    var body: some View {
        let localizer = model.language.localizer
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localizer.format(DiagnosticsText.probeInstructions, model.appName))
                .fixedSize(horizontal: false, vertical: true)
            ProbeTextView(runID: model.runID, onChange: model.textChanged)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .diagnosticsControl(.probeField, localizer)
            Button(action: model.start) { Text(verbatim: localizer.string(DiagnosticsText.probeStart)) }
                .disabled(model.isRunning)
                .diagnosticsControl(.probeStart, localizer)
            phase(localizer)
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 320)
        .respectsReduceMotion()
    }

    @ViewBuilder
    private func phase(_ localizer: Localizer) -> some View {
        switch model.phase {
        case .idle: EmptyView()
        case .running(let profile):
            Text(
                verbatim: localizer.format(
                    DiagnosticsText.probeRunning, localizer.string(DiagnosticsCopy.profileKey(profile))))
        case .done(let result):
            ForEach(result.results, id: \.profile) { line in
                Text(verbatim: DiagnosticsCopy.probeLine(line, localizer)).font(.callout.monospacedDigit())
            }
            Text(verbatim: localizer.string(DiagnosticsText.probeDone))
        case .unavailable:
            Text(verbatim: localizer.string(DiagnosticsText.probeUnavailable))
        }
    }
}

/// Plain `NSTextView` (PLT-R810 "plain text view") that reports every text change and takes focus when a run
/// starts, so the probe's keys land in it.
struct ProbeTextView: NSViewRepresentable {
    let runID: Int
    let onChange: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollablePlainDocumentContentTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isRichText = false
            text.isAutomaticTextCompletionEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isContinuousSpellCheckingEnabled = false
            text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            text.delegate = context.coordinator
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard context.coordinator.runID != runID, let text = view.documentView as? NSTextView else { return }
        context.coordinator.runID = runID
        text.string = ""
        text.window?.makeFirstResponder(text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: @MainActor () -> Void
        var runID = 0
        init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        func textDidChange(_ notification: Notification) { onChange() }
    }
}
