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
final class LatencyProbeWindowController: NSWindowController, NSWindowDelegate {
    private let model: LatencyProbeModel
    private var observers: [NSObjectProtocol] = []

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
        window.delegate = self
        model.hasFocus = { [weak window] in
            guard let window else { return false }
            return window.isKeyWindow && window.firstResponder is NSTextView
        }
        observeFocusLoss(of: window)
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.probeTitle) }
    }

    /// PLT-R810: the probe types into its own text view only. Losing key status or the app losing activation
    /// stops the run before the next key.
    private func observeFocusLoss(of window: NSWindow) {
        let center = NotificationCenter.default
        let stop: @Sendable (Notification) -> Void = { [weak model] _ in
            MainActor.assumeIsolated { model?.focusLost() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: stop),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stop),
        ]
    }

    func windowWillClose(_ notification: Notification) {
        model.focusLost()
    }
}

@MainActor
@Observable
final class LatencyProbeModel {
    enum Phase: Equatable {
        case idle
        case running(LatencyProbeResult.Profile)
        case done(LatencyProbeResult)
        case stopped
        case unavailable
    }

    let language: InterfaceLanguageModel
    let appName: String
    @ObservationIgnored let services: LatencyProbeServices
    /// Whether the probe window is key and its text view first responder (set by the window controller).
    @ObservationIgnored var hasFocus: @MainActor () -> Bool = { false }
    @ObservationIgnored private var stopSignal: ProbeStopSignal?
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
        let signal = ProbeStopSignal()
        stopSignal = signal
        phase = .running(.normal)
        Task { [weak self] in
            // Let the cleared text view become first responder before the first key is posted.
            try? await Task.sleep(nanoseconds: Self.focusDelay.unsignedNanoseconds)
            guard let self else { return }
            if !self.hasFocus() { signal.stop() }
            let result = await self.session.run(
                script: script, progress: { profile in Task { await self.show(profile, signal: signal) } },
                shouldContinue: { signal.shouldContinue() })
            self.finish(result)
        }
    }

    static let focusDelay: TimeSpan = .milliseconds(300)

    private var session: LatencyProbeSession {
        LatencyProbeSession(driver: services.driver, metrics: services.metrics, wallClock: services.wallClock)
    }

    /// Before each profile: the window must still have the focus, else the run stops (PLT-R810).
    private func show(_ profile: LatencyProbeResult.Profile, signal: ProbeStopSignal) {
        guard hasFocus() else { return signal.stop() }
        if isRunning { phase = .running(profile) }
    }

    /// The window resigned key, the app was deactivated or the window closes: no further key is posted.
    func focusLost() {
        guard isRunning else { return }
        stopSignal?.stop()
    }

    private func finish(_ result: LatencyProbeResult?) {
        stopSignal = nil
        guard let result else {
            phase = .stopped
            return
        }
        phase = .done(result)
        services.onResult(result)
    }

    /// Main thread, from the text view's change notification; `text` is the view's content after the change.
    func textChanged(_ text: String) {
        services.driver.textChanged(at: services.clock.now(), kind: LatencyProbeChange(text: text))
    }
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
        case .stopped:
            Text(verbatim: localizer.string(DiagnosticsText.probeStopped))
        case .unavailable:
            Text(verbatim: localizer.string(DiagnosticsText.probeUnavailable))
        }
    }
}

/// Plain `NSTextView` (PLT-R810 "plain text view") that reports every text change and takes focus when a run
/// starts, so the probe's keys land in it.
struct ProbeTextView: NSViewRepresentable {
    let runID: Int
    let onChange: @MainActor (String) -> Void

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
        let onChange: @MainActor (String) -> Void
        var runID = 0
        init(onChange: @escaping @MainActor (String) -> Void) { self.onChange = onChange }
        /// The content after the change tells whether it shows the measured run's composed character.
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            onChange(text.string)
        }
    }
}
