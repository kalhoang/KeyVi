// SPDX-License-Identifier: GPL-3.0-or-later
//
// "This app misbehaves" panel (PLT-R1205). The flow logic is InputHost's `MisbehavesFlow`; this file drives
// `GuidedTestRunner` with the host in pass-through and renders the steps.
//
// Keyboard focus (PLT-R1205 step 6, decision Q43): a non-activating panel whose key status follows ShellCore's
// `MisbehavesPanelFocus`. It becomes key while the user describes the symptom and during the final offers, so Tab
// and Full Keyboard Access reach its controls (PRD-R67), without activating this app. During the guided test it
// cannot become key and hands keyboard focus back to the problem field before each candidate, because the runner
// types into that field. The real focus behaviour is checked by hand (needsManualTestByPa).

import AppKit
import AppModel
import Combine
import CompatRules
import Diagnostics
import Injection
import InputHost
import RealtimeSupport
import ShellCore
import SwiftUI

/// Applies the panel's keyboard focus policy with AppKit (PLT-R1205 step 6).
@MainActor
protocol MisbehavesFocusDriving: AnyObject {
    func apply(_ focus: MisbehavesPanelFocus, action: MisbehavesFocusAction?)
}

/// A panel whose key status follows the flow's phase (`MisbehavesPanelFocus.panelCanBecomeKey`).
final class MisbehavesPanel: NSPanel {
    var acceptsKey = true

    override var canBecomeKey: Bool { acceptsKey }
}

@MainActor
final class MisbehavesPanelController: NSWindowController, NSWindowDelegate, MisbehavesFocusDriving {
    private let model: MisbehavesModel
    private let panel: MisbehavesPanel

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
        let panel = MisbehavesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: MisbehavesView(model: model))
        panel.center()
        self.panel = panel
        super.init(window: panel)
        panel.delegate = self
        WindowTitles.follow(language, window: panel) { $0.string(DiagnosticsText.misbehavesTitle) }
    }

    /// The model read the focus snapshot of the problem field when it was created; from now on the panel follows
    /// the focus policy, which takes keyboard focus for the symptom (PLT-R1205 steps 2 and 6).
    func present() {
        panel.orderFrontRegardless()
        model.focusDriver = self
    }

    func apply(_ focus: MisbehavesPanelFocus, action: MisbehavesFocusAction?) {
        panel.acceptsKey = focus.panelCanBecomeKey
        panel.becomesKeyOnlyIfNeeded = focus.panelBecomesKeyOnlyIfNeeded
        switch action {
        case .takeFocus?: panel.makeKeyAndOrderFront(nil)
        case .returnFocusToProblemField?: returnFocusToProblemField()
        case nil: break
        }
    }

    /// A non-activating panel never activates this app, so the app the user was typing in stays active while the
    /// panel is key. Ordering the key panel out hands keyboard focus back to that app's key window, whose focused
    /// element is the problem field; ordering it in again, now unable to become key, keeps it on screen. Nothing
    /// happens while the panel is not key, so a focus change the user made is never undone.
    private func returnFocusToProblemField() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        model.focusDriver = nil  // a closing panel takes no focus
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
    /// The typing task (candidates or the removal of an answered candidate's test text). While it runs the focus
    /// stays in the problem field: a step reached meanwhile (finished, stopped) moves the focus only once the
    /// runner has returned, so no test key can reach the panel (PLT-R1205 step 6).
    private var task: Task<Void, Never>? {
        didSet { syncFocus() }
    }
    /// Stop signal of the current guided test: set by Stop, by closing the panel and by an app switch; its focus
    /// check runs on the typing thread before every step (PLT-R1205 step 3, PLT-R387).
    private var stopSignal: ProbeStopSignal?
    /// Re-reads the gate's target after the panel handed the focus back (`MisbehavesRetarget.rereadDelays`).
    private var retargetTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    /// Bound to the host context read while the problem field had the focus (PLT-R1202): the panel takes the
    /// focus in steps 2 and 5, and a live read would then describe this app's own panel.
    private var reportBuilder: DiagnosticsServices.ReportBuilder?
    private var focusTracker = MisbehavesFocusTracker()
    /// Applies PLT-R1205 step 6; set by the panel once it is on screen, cleared when it closes.
    weak var focusDriver: (any MisbehavesFocusDriving)? {
        didSet { syncFocus() }
    }
    @Published var flow: MisbehavesFlow? {
        didSet { syncFocus() }
    }
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
        reportBuilder = services.reportSession?()
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
    /// field as the target. While the panel holds the focus the live focus is this app: the gate hands the focus
    /// back, and the target is read again once the problem field has it (PLT-R1205 steps 2 and 3).
    func requestGuidedTest() {
        let retargeted = retargetToLiveFocus()
        flow?.requestGuidedTest()
        guard !retargeted, flow?.step == .confirmField else { return }
        rereadTargetWhenFocusReturns()
    }

    /// Replaces the target with the live focus where `MisbehavesRetarget` allows it, keeping the symptom and the
    /// step; returns whether it did.
    private func retargetToLiveFocus() -> Bool {
        guard let focus = services.currentFocus?(),
            MisbehavesRetarget.takesLiveFocus(step: flow?.step, liveFocusIsThisApp: isThisApp(focus.app))
        else { return false }
        var next = MisbehavesFlow(target: MisbehavesTarget(focus: focus))
        next.symptom = flow?.symptom
        if flow?.step == .confirmField { next.requestGuidedTest() }
        flow = next
        rebindReport()
        return true
    }

    /// The window server hands keyboard focus back asynchronously, so the gate's target is read again a few
    /// times, until a read names the problem field or the step moves on.
    private func rereadTargetWhenFocusReturns() {
        retargetTask?.cancel()
        retargetTask = Task { [weak self] in
            for delay in MisbehavesRetarget.rereadDelays {
                try? await Task.sleep(nanoseconds: delay.unsignedNanoseconds)
                guard let self, !Task.isCancelled, self.flow?.step == .confirmField else { return }
                if self.retargetToLiveFocus() { return }
            }
        }
    }

    /// The test runs in the field focused at the moment of confirmation (PLT-R1205 step 3), never in this app.
    func confirmAndStart() {
        retargetTask?.cancel()
        guard task == nil, let focus = services.currentFocus?(), !isThisApp(focus.app) else {
            flow?.interrupt(.focusChanged)
            return
        }
        var next = MisbehavesFlow(target: MisbehavesTarget(focus: focus))
        next.symptom = flow?.symptom
        next.requestGuidedTest()
        next.confirmFieldIsEmptyAndSafe()
        flow = next
        rebindReport()
        guard let guided = services.guidedTest, let pid = next.target.app?.pid else { return }
        stopSignal = ProbeStopSignal(
            stillFocused: GuidedTestFocus.check(ax: guided.focusAX, pid: pid, field: next.target.fieldHandle))
        observeAppSwitch(away: pid)
        runPending()
    }

    /// The removal task is set before the flow moves on, so a final step reached by this answer takes the focus
    /// only after the test text is gone; the task body runs once this method returns.
    func answer(seesCanary: Bool) {
        guard task == nil, let candidate = flow?.questionCandidate, let stop = stopSignal else { return }
        task = Task { [weak self] in
            await self?.withPassThrough { runner, field in
                _ = await runner.removeTestText(candidate, field: field, stop: stop)
            }
            self?.task = nil
            self?.runPending()
        }
        flow?.answer(seesCanary: seesCanary)
        returnFocusToProblemField()
    }

    /// PLT-R1205 step 6: the focus policy follows the flow's step once the panel is on screen.
    private func syncFocus() {
        guard let focusDriver, task == nil else { return }
        let action = focusTracker.update(step: flow?.step)
        guard let phase = focusTracker.phase else { return }
        focusDriver.apply(phase, action: action)
    }

    /// PLT-R1205 step 6: before each candidate and before the test text is removed, the runner's field holds the
    /// keyboard focus.
    private func returnFocusToProblemField() {
        guard let focusDriver, let phase = focusTracker.phase else { return }
        focusDriver.apply(phase, action: MisbehavesPanelFocus.actionBeforeEachCandidate)
    }

    /// Stops typing at once: the runner reads the signal before every event. The task clears itself when the
    /// typing thread returns, so the pass-through is switched off exactly once.
    func stop() {
        retargetTask?.cancel()
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
                self.returnFocusToProblemField()
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

    /// The target changed while the problem field had the focus: the report describes the new target.
    private func rebindReport() {
        if let session = services.reportSession { reportBuilder = session() }
        refreshReport()
    }

    private func refreshReport() {
        if let build = reportBuilder {
            report = build(draft)
            return
        }
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
