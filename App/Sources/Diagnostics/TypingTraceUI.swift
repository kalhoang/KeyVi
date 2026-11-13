// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Record typing trace..." (PLT-R905, D26): a confirmation that explains what is recorded, the capture HUD with
// countdown and Stop on all Spaces, the changed menu-bar icon, then a review window with export and discard.
// Closing the review without exporting discards the trace.

import AppKit
import AppModel
import Diagnostics
import InputHost
import Observation
import ShellCore
import SwiftUI

@MainActor
final class TypingTraceCoordinator {
    static let durations = [60, 120, 180]  // seconds, PLT-R905 default and maximum

    private let language: InterfaceLanguageModel
    private let services: TypingTraceServices
    private let appName: String
    private var session: TypingTraceSession?
    private var hud: CaptureHUDController?
    private var review: TypingTraceReviewController?

    init(language: InterfaceLanguageModel, services: TypingTraceServices, appName: String) {
        self.language = language
        self.services = services
        self.appName = appName
    }

    /// Explicit action only, after the confirmation (PLT-R905).
    func confirmAndStart(over window: NSWindow?) {
        if case .recording = session?.state { return }
        let localizer = language.localizer
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        for seconds in Self.durations {
            picker.addItem(withTitle: localizer.format(DiagnosticsText.traceSeconds, seconds))
        }
        picker.setAccessibilityLabel(localizer.string(DiagnosticsControl.traceDuration.labelKey))
        picker.setAccessibilityHelp(localizer.string(DiagnosticsControl.traceDuration.hintKey))
        let alert = NSAlert()
        alert.messageText = localizer.string(DiagnosticsText.traceConfirmTitle)
        alert.informativeText = localizer.format(
            DiagnosticsText.traceConfirmMessage, appName, Self.durations[0])
        alert.accessoryView = picker
        let startButton = alert.addButton(withTitle: localizer.string(DiagnosticsText.traceStart))
        startButton.setAccessibilityHelp(localizer.string(DiagnosticsControl.traceStart.hintKey))
        alert.addButton(withTitle: localizer.string(CommonText.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        record(seconds: Self.durations[max(0, picker.indexOfSelectedItem)])
    }

    private func record(seconds: Int) {
        let session = TypingTraceSession(
            capture: services.capture, scheduler: services.scheduler, wallClock: services.wallClock
        ) { [weak self] state in
            Task { @MainActor [weak self] in self?.render(state) }
        }
        self.session = session
        hud = CaptureHUDController(language: language) { [weak session] in session?.stop() }
        session.start(duration: TypingTraceSession.duration(seconds: seconds))
    }

    private func render(_ state: TypingTraceSession.State) {
        switch state {
        case .recording(_, let remaining):
            services.captureStateChanged(true)
            hud?.show(remaining: remaining)
        case .finished:
            endRecording()
            showReview()
        case .exported, .discarded, .idle:
            endRecording()
        case .failed(let failure):
            endRecording()
            review?.show(failure: Self.failureKey(failure))
        }
    }

    private func endRecording() {
        services.captureStateChanged(false)
        hud?.hide()
    }

    private func showReview() {
        guard let session, let text = session.review(language: language.localizer.language) else { return }
        let controller = TypingTraceReviewController(language: language, text: text, session: session)
        review = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func failureKey(_ failure: TypingTraceSession.Failure) -> DiagnosticsText {
        switch failure {
        case .alreadyRecording: .traceAlreadyRecording
        case .invalidDuration: .traceInvalidDuration
        case .unknownSession: .traceUnknownSession
        case .storage: .traceStorage
        }
    }
}

@MainActor
@Observable
final class TypingTraceReviewModel {
    let language: InterfaceLanguageModel
    let text: String
    @ObservationIgnored let session: TypingTraceSession
    @ObservationIgnored var window: () -> NSWindow? = { nil }
    @ObservationIgnored var close: () -> Void = {}
    var status: DiagnosticsText?

    init(language: InterfaceLanguageModel, text: String, session: TypingTraceSession) {
        self.language = language
        self.text = text
        self.session = session
    }

    func export() {
        let name = "trace-" + Self.stamp() + ".jsonl"
        ReportActions.save(
            suggestedName: name, over: window(), write: { [session] url in session.export(to: url) },
            done: { [weak self] exported in
                guard let exported else { return }
                self?.status = exported ? .traceExported : .traceStorage
                if exported { self?.close() }
            })
    }

    func discard() {
        session.discard()
        close()
    }

    private static func stamp() -> String {
        Date().formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false)
        )
        .replacingOccurrences(of: ":", with: "")
    }
}

@MainActor
final class TypingTraceReviewController: NSWindowController, NSWindowDelegate {
    private let model: TypingTraceReviewModel

    required init?(coder: NSCoder) { nil }

    init(language: InterfaceLanguageModel, text: String, session: TypingTraceSession) {
        model = TypingTraceReviewModel(language: language, text: text, session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: TypingTraceReviewView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.window = { [weak self] in self?.window }
        model.close = { [weak self] in self?.close() }
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.traceReviewTitle) }
    }

    func show(failure: DiagnosticsText) { model.status = failure }

    /// PLT-R905: closing without export deletes the trace at once.
    func windowWillClose(_ notification: Notification) {
        if case .finished = model.session.state { model.session.discard() }
    }
}

struct TypingTraceReviewView: View {
    let model: TypingTraceReviewModel

    var body: some View {
        let localizer = model.language.localizer
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localizer.string(DiagnosticsText.traceReviewNote)).fixedSize(
                horizontal: false, vertical: true)
            ReportTextView(text: model.text, control: .traceText, localizer: localizer)
            HStack {
                Button(action: model.export) { Text(verbatim: localizer.string(DiagnosticsText.traceExport)) }
                    .diagnosticsControl(.traceExport, localizer)
                Button(action: model.discard) { Text(verbatim: localizer.string(DiagnosticsText.traceDiscard)) }
                    .diagnosticsControl(.traceDiscard, localizer)
            }
            if let status = model.status {
                Text(verbatim: localizer.string(status)).font(.callout)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 360)
    }
}
