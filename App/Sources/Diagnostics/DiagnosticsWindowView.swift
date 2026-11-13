// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics window content (PLT-R1201): the health state in plain words, the exact report text (which holds
// permissions, secure input, focus, rule, latency and recent health events, PLT-R1202) and the five buttons.

import AppKit
import AppModel
import Diagnostics
import Observation
import ShellCore
import SwiftUI

@MainActor
@Observable
final class DiagnosticsWindowModel {
    let language: InterfaceLanguageModel
    @ObservationIgnored let services: DiagnosticsServices
    @ObservationIgnored private let makeReport: @MainActor () -> DiagnosticsReport
    @ObservationIgnored var perform: (DiagnosticsWindowAction) -> Void = { _ in }
    private(set) var report: DiagnosticsReport?
    private(set) var status: DiagnosticsText?

    init(
        language: InterfaceLanguageModel, services: DiagnosticsServices,
        report: @escaping @MainActor () -> DiagnosticsReport
    ) {
        self.language = language
        self.services = services
        makeReport = report
    }

    var localizer: Localizer { language.localizer }

    /// Buttons offered: a driver without its service is left out.
    var actions: [DiagnosticsWindowAction] {
        DiagnosticsWindowAction.allCases.filter { action in
            switch action {
            case .copyReport, .misbehaves: true
            case .recordTrace: services.trace != nil
            case .latencyTest: services.latency != nil
            case .openLogs: services.logsFolder != nil
            }
        }
    }

    func refresh() {
        report = makeReport()
        status = nil
    }

    func currentReport() -> DiagnosticsReport {
        if let report { return report }
        let fresh = makeReport()
        report = fresh
        return fresh
    }

    /// The exact text that "Copy report" writes as the issue block (PLT-R1204: shown before copying).
    var reportText: String {
        report.map { DiagnosticsRenderer.plainText($0, language: localizer.language) } ?? ""
    }

    func copyReport() {
        ReportActions.copy(DiagnosticsRenderer.issueBlock(currentReport()))
        status = .copied
    }

    func openLogs() {
        guard let folder = services.logsFolder, ReportActions.openFolder(folder) else {
            status = .logsUnavailable
            return
        }
        status = nil
    }

    static func title(_ action: DiagnosticsWindowAction) -> DiagnosticsControl {
        switch action {
        case .copyReport: .copyReport
        case .misbehaves: .misbehaves
        case .recordTrace: .recordTrace
        case .latencyTest: .latencyTest
        case .openLogs: .openLogs
        }
    }
}

struct DiagnosticsWindowView: View {
    let model: DiagnosticsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text(verbatim: DiagnosticsCopy.stateLine(report.hostState, localizer))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(verbatim: localizer.string(DiagnosticsText.reportNote))
                .font(.callout)
                .foregroundStyle(.secondary)
            ReportTextView(text: model.reportText, control: .reportText, localizer: localizer)
            Text(verbatim: localizer.format(DiagnosticsText.clipboardNotice, model.services.resolvedBrand.displayName))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actionRow(localizer)
            if let status = model.status {
                Text(verbatim: localizer.string(status))
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
        .respectsReduceMotion()
    }

    private func actionRow(_ localizer: Localizer) -> some View {
        HStack(spacing: 8) {
            ForEach(model.actions, id: \.self) { action in
                let control = DiagnosticsWindowModel.title(action)
                Button(localizer.string(control.labelKey)) { model.perform(action) }
                    .diagnosticsControl(control, localizer)
                    .keyboardShortcut(action == .copyReport ? .defaultAction : nil)
            }
        }
    }
}

/// Read-only, selectable, scrollable monospaced text that keyboard users can focus (PRD-R67).
struct ReportTextView: View {
    let text: String
    let control: DiagnosticsControl
    let localizer: Localizer

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .focusable()
        .diagnosticsControl(control, localizer)
    }
}

extension View {
    /// VoiceOver label and hint from the Diagnostics table (PRD-R66, workstream rule 8).
    func diagnosticsControl(_ control: DiagnosticsControl, _ localizer: Localizer) -> some View {
        accessibilityLabel(Text(verbatim: localizer.string(control.labelKey)))
            .accessibilityHint(Text(verbatim: localizer.string(control.hintKey)))
    }
}

/// PRD-R67: with Reduce Motion on, no view in the Diagnostics windows animates (disclosure groups included).
struct ReduceMotionTransactions: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            guard reduceMotion else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

extension View {
    func respectsReduceMotion() -> some View { modifier(ReduceMotionTransactions()) }
}
