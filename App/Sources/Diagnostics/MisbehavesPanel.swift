// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "This app misbehaves" panel (PLT-R1205): a non-activating panel, so the problem field keeps keyboard focus
// while the guided test types into it. The flow logic is ShellCore/InputHost's `MisbehavesFlow`; this file
// drives `GuidedTestRunner` with the host in pass-through and renders the steps.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import Injection
import InputHost
import Observation
import ShellCore
import SwiftUI

@MainActor
final class MisbehavesPanelController: NSWindowController, NSWindowDelegate {
    private let model: MisbehavesModel

    required init?(coder: NSCoder) { nil }

    init(
        language: InterfaceLanguageModel, services: DiagnosticsServices,
        report: @escaping @MainActor () -> DiagnosticsReport?
    ) {
        model = MisbehavesModel(language: language, services: services, report: report)
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
@Observable
final class MisbehavesModel {
    let language: InterfaceLanguageModel
    @ObservationIgnored let services: DiagnosticsServices
    @ObservationIgnored private let baseReport: @MainActor () -> DiagnosticsReport?
    @ObservationIgnored private var task: Task<Void, Never>?
    var flow: MisbehavesFlow?
    private(set) var status: DiagnosticsText?
    private(set) var running = false
    /// Shown in the preview and used by "Copy report" and "Open GitHub issue" unchanged (PLT-R1204).
    private(set) var report: DiagnosticsReport?
    var previewExpanded = false

    init(
        language: InterfaceLanguageModel, services: DiagnosticsServices,
        report: @escaping @MainActor () -> DiagnosticsReport?
    ) {
        self.language = language
        self.services = services
        baseReport = report
        flow = services.currentFocus.map { MisbehavesFlow(target: MisbehavesTarget(focus: $0())) }
        refreshReport()
    }

    var localizer: Localizer { language.localizer }
    var brand: Brand { services.resolvedBrand }

    /// The guided test needs the runner, the host's pass-through and a target that may be typed into.
    var canOfferGuidedTest: Bool { services.guidedTest != nil && flow?.target.canRunGuidedTest == true }

    func select(_ symptom: DiagnosticsReport.Symptom) {
        flow?.symptom = symptom
        refreshReport()
    }

    func requestGuidedTest() { flow?.requestGuidedTest() }

    /// The test runs in the field focused at the moment of confirmation (PLT-R1205 step 3), never in this app.
    func confirmAndStart() {
        guard let focus = services.currentFocus?(), focus.app?.bundle.rawValue != brand.bundleIdentifier else {
            flow?.interrupt(.focusChanged)
            return
        }
        var next = MisbehavesFlow(target: MisbehavesTarget(focus: focus))
        next.symptom = flow?.symptom
        next.requestGuidedTest()
        next.confirmFieldIsEmptyAndSafe()
        flow = next
        runPending()
    }

    func answer(seesCanary: Bool) {
        guard let candidate = flow?.questionCandidate else { return }
        flow?.answer(seesCanary: seesCanary)
        task = Task { [weak self] in
            await self?.withPassThrough { runner, field in _ = await runner.removeTestText(candidate, field: field) }
            self?.task = nil
            self?.runPending()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        flow?.interrupt(.cancelled)
    }

    /// Runs candidates until a human question, the end, or an interruption (PLT-R1205 step 3).
    private func runPending() {
        guard task == nil, flow?.pendingCandidate != nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled, let pending = self.flow?.pendingCandidate {
                guard self.focusUnchanged() else {
                    self.flow?.interrupt(.focusChanged)
                    break
                }
                let result = await self.withPassThrough { runner, field in
                    await runner.run(pending.candidate, field: field)
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
        running = true
        guided.setPassThrough(true)
        let value = await body(guided.runner, flow?.target.fieldHandle)
        guided.setPassThrough(false)
        running = false
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
            ReportActions.copy(DiagnosticsRenderer.issueBlock(report))
            status = .copied
        case .openGitHubIssue: openGitHubIssue()
        }
    }

    private var draft: BugReportDraft {
        BugReportDraft(
            app: flow?.target.app?.bundle, appName: nil, symptom: flow?.symptom ?? .other, userDescription: "",
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

    var previewText: String {
        report.map { DiagnosticsRenderer.plainText($0, language: localizer.language) } ?? ""
    }

    private func openGitHubIssue() {
        guard let repository = brand.repositoryURL, let report else { return }
        ReportActions.copy(DiagnosticsRenderer.issueBlock(report))  // after the visible notice (PRD-R48)
        ReportActions.open(BugReportComposer.githubIssueURL(repository: repository, draft: draft, report: report))
        status = .githubPasteHint
    }
}
