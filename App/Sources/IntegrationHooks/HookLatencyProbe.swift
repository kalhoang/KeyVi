// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The `latencyProbe` hook (PLT-R810, T4 of 02-platform.md 8.1 for the runner's bench, ADR 0502): the built-in
// latency probe with one timing profile, typed into a plain text view in a window of its own, without the
// Diagnostics window. Test build only. The run stops (answer `busy`) when the window loses key status or the app is
// deactivated, like the Diagnostics probe; no partial result is returned.

#if INTEGRATION_HOOKS
import AppKit
import AppModel
import Diagnostics
import InputHost
import RealtimeSupport
import ShellCore

@MainActor
final class HookLatencyProbe: NSObject, NSTextViewDelegate {
    /// Lets the cleared text view become first responder before the first key is posted.
    static let focusDelay: TimeSpan = .milliseconds(300)

    private let host: InputHostController
    private let metrics: PlatformMetrics
    private let language: InterfaceLanguageModel
    private let method: @MainActor () -> TypingMethod
    private var driver: LatencyProbeDriver?
    private var running = false

    init(
        host: InputHostController, metrics: PlatformMetrics, language: InterfaceLanguageModel,
        method: @escaping @MainActor () -> TypingMethod
    ) {
        self.host = host
        self.metrics = metrics
        self.language = language
        self.method = method
    }

    func run(_ profile: LatencyProbeResult.Profile) async -> LatencyProbeOutcome {
        guard !running else { return .interrupted }
        guard let layout = host.currentLayoutTable(),
            let script = LatencyProbeScript.standard(layout: layout, method: method())
        else { return .unavailable }
        running = true
        defer { running = false }
        let driver = host.makeLatencyProbeDriver()
        self.driver = driver
        let (window, text) = makeWindow()
        let stop = HookProbeStop()
        let observers = observeFocusLoss(of: window, stop: stop)
        defer {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            window.close()
            self.driver = nil
        }
        NSApp.bringToFront()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        try? await Task.sleep(nanoseconds: Self.focusDelay.unsignedNanoseconds)
        guard window.isKeyWindow, window.firstResponder === text else { return .interrupted }
        let session = LatencyProbeSession(driver: driver, metrics: metrics, wallClock: SystemWallClock())
        let result = await session.run(script: script, profiles: [profile], shouldContinue: { stop.shouldContinue })
        return result.map(LatencyProbeOutcome.result) ?? .interrupted
    }

    /// A plain text view (PLT-R810): no substitutions, no completion, so only the probe's own edits change it.
    private func makeWindow() -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let localizer = language.localizer
        window.title = localizer.string(DiagnosticsText.probeTitle)
        let scroll = NSTextView.scrollablePlainDocumentContentTextView()
        let text = scroll.documentView as? NSTextView ?? NSTextView()
        text.isRichText = false
        text.isAutomaticTextCompletionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.delegate = self
        text.setAccessibilityLabel(localizer.string(DiagnosticsControl.probeField.labelKey))
        text.setAccessibilityHelp(localizer.string(DiagnosticsControl.probeField.hintKey))
        window.contentView = scroll
        window.center()
        return (window, text)
    }

    private func observeFocusLoss(of window: NSWindow, stop: HookProbeStop) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let signal: @Sendable (Notification) -> Void = { _ in stop.stop() }
        return [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: signal),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: signal),
        ]
    }

    /// Every change of the view's content goes to the driver with the time it happened (PLT-R810 "text-change
    /// times"); the content itself only decides whether the change shows the composed character.
    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        driver?.textChanged(at: MachClock().now(), kind: LatencyProbeChange(text: text.string))
    }
}

/// Set from the main queue's focus notifications, read by the probe session before every key.
final class HookProbeStop: Sendable {
    private let stopped = Atomic<Bool>(false)
    func stop() { stopped.store(true, ordering: .releasing) }
    var shouldContinue: Bool { !stopped.load(ordering: .acquiring) }
}
#endif
