// SPDX-License-Identifier: GPL-3.0-or-later
//
// "This app misbehaves" panel (PLT-R1205): a non-activating panel, so the problem field keeps keyboard focus
// while the guided test types into it. The flow logic is ShellCore/InputHost's `MisbehavesFlow`; this file
// drives `GuidedTestRunner` with the host in pass-through and renders the steps.
//
// Known limitation (PRD-R66): because the panel never becomes key, Tab and Full Keyboard Access cannot reach its
// buttons; VoiceOver users operate them through the VoiceOver cursor. Making the panel key would take focus
// from the field under test, which the guided test must type into. Verified by hand (needsManualTestByPa).

import AppKit
import AppModel
import Combine
import CompatRules
import Diagnostics
import Injection
import InputHost
import ShellCore
import SwiftUI

@MainActor
final class MisbehavesPanelController: NSWindowController, NSWindowDelegate {
    private let model: MisbehavesModel

    required init?(coder: NSCoder) { nil }

    /// `bundle` is the app the menu item was chosen for; it stands in for the live focus while the focus is in
    /// this app's own windows (opened from the Diagnostics window).
    init(
        language: InterfaceLanguageModel, services: DiagnosticsServices, bundle: BundleKey?,
        report: @escaping @MainActor () -> DiagnosticsReport?,
        openBugReport: @escaping @MainActor (BundleKey?, DiagnosticsReport.Symptom) -> Void
    ) {
        model = MisbehavesModel(
            language: language, services: services, fallbackBundle: bundle, report: report,
            openBugReport: openBugReport)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: MisbehavesView(model: model))
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        WindowTitles.follow(language, window: panel) { $0.string(DiagnosticsText.misbehavesTitle) }
    }

    func present() {
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

@MainActor
final class MisbehavesModel: ObservableObject {
    let language: InterfaceLanguageModel
    let services: DiagnosticsServices
    private let baseReport: @MainActor () -> DiagnosticsReport?
    private let fallbackBundle: BundleKey?
    private let continueToBugReport: @MainActor (BundleKey?, DiagnosticsReport.Symptom) -> Void
    private var task: Task<Void, Never>?
    /// Stop signal of the current guided test: set by Stop, by closing the panel and by an app switch; its focus
    /// check runs on the typing thread before every step (PLT-R1205 step 3, PLT-R387).
    private var stopSignal: ProbeStopSignal?
    private var activationObserver: NSObjectProtocol?
    @Published var flow: MisbehavesFlow?
    @Published private(set) var status: DiagnosticsText?
    /// Shown in the preview and used by "Copy report" and "Open GitHub issue" unchanged (PLT-R1204).
    @Published private(set) var report: DiagnosticsReport?
    @Published var previewExpanded = false

    init(
        language: InterfaceLanguageModel, services: DiagnosticsServices, fallbackBundle: BundleKey?,
        report: @escaping @MainActor () -> DiagnosticsReport?,
        openBugReport: @escaping @MainActor (BundleKey?, DiagnosticsReport.Symptom) -> Void
    ) {
        self.language = language
        self.services = services
        self.fallbackBundle = fallbackBundle
        continueToBugReport = openBugReport
        baseReport = report
        flow = services.currentFocus.map { MisbehavesFlow(target: MisbehavesTarget(focus: $0())) }
        refreshReport()
    }

    var localizer: Localizer { language.localizer }
    var brand: Brand { services.resolvedBrand }

    /// The guided test needs the runner with the host's diagnostics pass-through and a target that may be typed
    /// into; without the pass-through hook it is never offered (PLT-R1205 step 3).
    var canOfferGuidedTest: Bool {
        flow?.target.offersGuidedTest(hostPassThroughAvailable: services.guidedTest != nil) == true
    }

    /// The detected target is this app's own window (the panel was opened from the Diagnostics window): the
    /// panel asks the user to click into the problem field first.
    var targetIsThisApp: Bool { isThisApp(flow?.target.app) }

    private func isThisApp(_ app: FocusedApp?) -> Bool { app?.bundle.rawValue == brand.bundleIdentifier }

    func select(_ symptom: DiagnosticsReport.Symptom) {
        flow?.symptom = symptom
        refreshReport()
    }

    /// Re-reads the live focus, so a user who clicked into the problem field after opening the panel sees that
    /// field as the target.
    func requestGuidedTest() {
        if let focus = services.currentFocus?(), !isThisApp(focus.app) {
            var next = MisbehavesFlow(target: MisbehavesTarget(focus: focus))
            next.symptom = flow?.symptom
            flow = next
            refreshReport()
        }
        flow?.requestGuidedTest()
    }

    /// The test runs in the field focused at the moment of confirmation (PLT-R1205 step 3), never in this app.
    func confirmAndStart() {
        guard task == nil, let focus = services.currentFocus?(), !isThisApp(focus.app) else {
            flow?.interrupt(.focusChanged)
            return
        }
        var next = MisbehavesFlow(target: MisbehavesTarget(focus: focus))
        next.symptom = flow?.symptom
        next.requestGuidedTest()
        next.confirmFieldIsEmptyAndSafe()
        flow = next
        guard let guided = services.guidedTest, let pid = next.target.app?.pid else { return }
        stopSignal = ProbeStopSignal(
            stillFocused: GuidedTestFocus.check(ax: guided.focusAX, pid: pid, field: next.target.fieldHandle))
        observeAppSwitch(away: pid)
        runPending()
    }

    func answer(seesCanary: Bool) {
        guard let candidate = flow?.questionCandidate, let stop = stopSignal else { return }
        flow?.answer(seesCanary: seesCanary)
        task = Task { [weak self] in
            await self?.withPassThrough { runner, field in
                _ = await runner.removeTestText(candidate, field: field, stop: stop)
            }
            self?.task = nil
            self?.runPending()
        }
    }

    /// Stops typing at once: the runner reads the signal before every event. The task clears itself when the
    /// typing thread returns, so the pass-through is switched off exactly once.
    func stop() {
        stopSignal?.stop()
        task?.cancel()
        flow?.interrupt(.cancelled)
        endAppSwitchObservation()
    }

    /// Another app became active while the test was due to type (PLT-R1205 step 3).
    private func focusMoved() {
        stopSignal?.stop()
        flow?.interrupt(.focusChanged)
        endAppSwitchObservation()
    }

    private func observeAppSwitch(away pid: Int32) {
        endAppSwitchObservation()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPID = activated?.processIdentifier
            MainActor.assumeIsolated {
                guard activatedPID != pid else { return }
                self?.focusMoved()
            }
        }
    }

    private func endAppSwitchObservation() {
        guard let activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    /// Runs candidates until a human question, the end, or an interruption (PLT-R1205 step 3).
    private func runPending() {
        guard task == nil, let stop = stopSignal, flow?.pendingCandidate != nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled, !stop.isStopped, let pending = self.flow?.pendingCandidate {
                guard self.focusUnchanged() else {
                    self.focusMoved()
                    break
                }
                let result = await self.withPassThrough { runner, field in
                    await runner.run(pending.candidate, field: field, stop: stop)
                }
                guard !Task.isCancelled, let result else { break }
                self.flow?.record(result)
            }
            self?.task = nil
        }
    }

    /// The host passes the runner's events unchanged only while the runner types.
    private func withPassThrough<Value>(
        _ body: (GuidedTestRunner, FieldHandle?) async -> Value
    ) async -> Value? {
        guard let guided = services.guidedTest else { return nil }
        guided.setPassThrough(true)
        let value = await body(guided.runner, flow?.target.fieldHandle)
        guided.setPassThrough(false)
        return value
    }

    /// Typing stops when the field of the target is no longer focused.
    private func focusUnchanged() -> Bool {
        guard let target = flow?.target, let current = services.currentFocus?() else { return false }
        guard current.app?.bundle == target.app?.bundle else { return false }
        guard let handle = target.fieldHandle else { return true }
        return current.fieldHandle?.pid == handle.pid && current.fieldHandle?.token == handle.token
    }

    var suggestion: Rule? {
        guard let guided = services.guidedTest else { return nil }
        return flow?.suggestion(macOS: guided.macOSVersion, date: guided.today())
    }

    /// Shown and copied on its own, never inside the report (ADR 0312).
    var suggestionJSON: String? {
        guard let suggestion else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(suggestion)).map { String(decoding: $0, as: UTF8.self) }
    }

    func perform(_ offer: MisbehavesOffer) {
        switch offer {
        case .useForMe:
            guard let suggestion, let apply = services.applyOverride else { return }
            apply(suggestion)
            status = .applied
        case .copySuggestion:
            guard let suggestionJSON else { return }
            ReportActions.copy(suggestionJSON)
            status = .copied
        case .copyReport:
            guard let report else { return }
            ReportActions.copy(ReportPreviewFormat.copiedBlock.text(report))
            status = .copied
        case .openGitHubIssue: openGitHubIssue()
        }
    }

    /// PRD-R47, PRD-R49: the bug report sheet, pre-filled with the reported app and the chosen symptom, for the
    /// paths this panel does not offer (email, save to a file, free text, preview).
    func openFullReport() {
        continueToBugReport(reportedBundle, flow?.symptom ?? .other)
    }

    /// The app the report names: the detected app, or the menu's app while the focus is in this app.
    private var reportedBundle: BundleKey? { targetIsThisApp ? fallbackBundle : flow?.target.app?.bundle }

    private var draft: BugReportDraft {
        BugReportDraft(
            app: reportedBundle, appName: nil, symptom: flow?.symptom ?? .other, userDescription: "",
            reproducesInPracticeField: nil)
    }

    private func refreshReport() {
        if let build = services.reportForDraft {
            report = build(draft)
            return
        }
        guard var fresh = baseReport() else { return }
        fresh.userReport = DiagnosticsReport.UserReportSection(
            symptom: draft.symptom, reportedApp: draft.app, reproducesInPracticeField: nil)
        report = fresh
    }

    /// Exactly the block that "Copy report" and "Open GitHub issue" write (PLT-R1204).
    var previewText: String { report.map(ReportPreviewFormat.copiedBlock.text) ?? "" }

    private func openGitHubIssue() {
        guard let repository = brand.repositoryURL, let report else { return }
        ReportActions.copy(ReportPreviewFormat.copiedBlock.text(report))  // after the visible notice (PRD-R48)
        ReportActions.open(BugReportComposer.githubIssueURL(repository: repository, draft: draft, report: report))
        status = .githubPasteHint
    }
}
