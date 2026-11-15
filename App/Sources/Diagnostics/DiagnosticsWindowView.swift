// SPDX-License-Identifier: GPL-3.0-or-later
//
// Diagnostics window content (PLT-R1201): the health state in plain words, the health notices of the last 24 hours
// with a label and an explanation (PLT-R397B), the report in the interface language (permission states, secure input
// with the likely holder, focused app and field, matched rule with strategy, parameters and source, latency
// percentiles and recent health events, PLT-R1202, PRD-R62), the latency histograms, the exact text that "Copy
// report" copies right above the buttons (PLT-R1204) and the five buttons.

import AppKit
import AppModel
import Combine
import Diagnostics
import ShellCore
import SwiftUI

@MainActor
final class DiagnosticsWindowModel: ObservableObject {
    let language: InterfaceLanguageModel
    let services: DiagnosticsServices
    private let makeReport: @MainActor () -> DiagnosticsReport
    var perform: (DiagnosticsWindowAction) -> Void = { _ in }
    @Published private(set) var report: DiagnosticsReport?
    @Published private(set) var status: DiagnosticsText?

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

    /// `build` replaces the live report (the bug report sheet's report of the same moment).
    func refresh(using build: (@MainActor () -> DiagnosticsReport)? = nil) {
        report = build?() ?? makeReport()
        status = nil
    }

    /// A new live report, without changing what the window shows.
    func freshReport() -> DiagnosticsReport { makeReport() }

    func currentReport() -> DiagnosticsReport {
        if let report { return report }
        let fresh = makeReport()
        report = fresh
        return fresh
    }

    /// The shown report in the interface language, the exact text "Copy report" writes and the histograms.
    var display: ReportDisplay? { report.map { ReportDisplay(report: $0, language: localizer.language) } }

    /// PLT-R1201, PLT-R397B: the health events of the shown report that call for a plain explanation.
    var notices: [HealthNoticeText] {
        report.map { DiagnosticsCopy.notices(for: $0, appName: services.resolvedBrand.displayName, localizer) } ?? []
    }

    @Published var histogramsExpanded = false
    @Published var copyPreviewExpanded = false

    func copyReport() {
        ReportActions.copy(ReportPreviewFormat.copiedBlock.text(currentReport()))
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
    @ObservedObject var model: DiagnosticsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 12) {
            if let report = model.report {
                Text(verbatim: DiagnosticsCopy.stateLine(report.hostState, localizer))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(model.notices, id: \.self) { notice in HealthNoticeView(notice: notice) }
            let display = model.display
            ReportTextView(text: display?.information ?? "", control: .reportInformation, localizer: localizer)
            DisclosureGroup(isExpanded: $model.histogramsExpanded) {
                ScrollView {
                    LatencyHistogramsView(histograms: display?.histograms ?? [], localizer: localizer)
                        .padding(.vertical, 4)
                }
                .frame(minHeight: 120, maxHeight: 240)
            } label: {
                Text(verbatim: localizer.string(DiagnosticsText.latencyHeading))
            }
            .diagnosticsControl(.latencyHistograms, localizer)
            DisclosureGroup(isExpanded: $model.copyPreviewExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: localizer.string(DiagnosticsText.reportNote))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ReportTextView(text: display?.copyPreview ?? "", control: .reportText, localizer: localizer)
                        .frame(minHeight: 120, maxHeight: 220)
                }
            } label: {
                Text(verbatim: localizer.string(DiagnosticsText.copyPreviewDisclosure))
            }
            .diagnosticsControl(.copyPreview, localizer)
            Text(verbatim: clipboardNotice(localizer))
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

    /// PRD-R48: names the window's only clipboard button.
    private func clipboardNotice(_ localizer: Localizer) -> String {
        DiagnosticsCopy.clipboardNotice(
            buttons: DiagnosticsCopy.windowClipboardControls, appName: model.services.resolvedBrand.displayName,
            localizer)
    }

    private func actionRow(_ localizer: Localizer) -> some View {
        HStack(spacing: 8) {
            ForEach(model.actions, id: \.self) { action in
                let control = DiagnosticsWindowModel.title(action)
                Button(localizer.string(control.labelKey)) { model.perform(action) }
                    .diagnosticsControl(control, localizer)
                    .keyboardShortcut(.defaultAction, when: action == .copyReport)
            }
        }
    }
}

/// One health notice (PLT-R1201, PLT-R397B): its label above its explanation, read by VoiceOver as one element.
struct HealthNoticeView: View {
    let notice: HealthNoticeText

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: notice.label).font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
            Text(verbatim: notice.explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

/// PLT-R1201 latency histograms: per metric its name, sample count and one bar per bucket with the bucket's upper
/// bound and count in text, so nothing relies on bar length or colour alone (PRD-R67).
struct LatencyHistogramsView: View {
    static let barWidth: CGFloat = 180
    let histograms: [LatencyHistogram]
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(histograms) { histogram in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: localizer.string(histogram.metric.title)).font(.subheadline)
                        Spacer()
                        Text(verbatim: samples(histogram.samples)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    if histogram.bins.isEmpty {
                        Text(verbatim: localizer.string(DiagnosticsText.latencyEmpty))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(histogram.bins.enumerated()), id: \.offset) { _, bin in row(bin) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ bin: LatencyHistogram.Bin) -> some View {
        let bound = LatencyHistograms.label(nanoseconds: bin.upperBoundNanoseconds, locale: localizer.locale)
        let count = localizer.formatNumber(Int(clamping: bin.count))
        return HStack(spacing: 6) {
            Text(verbatim: localizer.format(DiagnosticsText.latencyUpTo, bound))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 84, alignment: .trailing)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: max(bin.count > 0 ? 2 : 0, Self.barWidth * bin.fraction), height: 8)
                .frame(width: Self.barWidth, alignment: .leading)
            Text(verbatim: count).font(.system(.caption, design: .monospaced))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: localizer.format(DiagnosticsText.latencyBin, bound, count)))
    }

    private func samples(_ count: UInt64) -> String {
        localizer.format(DiagnosticsText.latencySamples, localizer.formatNumber(Int(clamping: count)))
    }
}
