// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the report previews show (PLT-R1204, PRD-R47 item 4): byte for byte the text a path writes, never a
// paraphrase. The Diagnostics window and the "This app misbehaves" panel copy only the block, so they show the
// block; the bug report sheet also attaches or saves the JSON file, so its preview offers both. The Diagnostics
// window also shows the same report in the interface language (PLT-R1201, PRD-R62).

public import AppModel
public import Diagnostics
internal import Foundation

public enum ReportPreviewFormat: String, Sendable, Hashable, CaseIterable {
    /// The diagnostics block (ADR 0501) that "Copy report" and "Mở GitHub" put on the clipboard.
    case copiedBlock
    /// The JSON file that "Gửi qua email" attaches and "Lưu tệp..." saves (PLT-R1202 "plain text and JSON").
    case attachedFile

    /// Exactly the text the paths of this format write. The JSON is empty only when it cannot be encoded, in
    /// which case those paths fail as well and say so.
    public func text(_ report: DiagnosticsReport) -> String {
        switch self {
        case .copiedBlock: DiagnosticsRenderer.issueBlock(report)
        case .attachedFile: (try? DiagnosticsRenderer.json(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// The sheet buttons whose output this format shows.
    public var paths: [BugReportAction] {
        switch self {
        case .copiedBlock: [.copyReport, .github]
        case .attachedFile: [.email, .saveFile]
        }
    }
}

/// What the Diagnostics window shows of one report: the PLT-R1201 information in the interface language (the
/// plain-text report, PLT-R1202), the exact text "Copy report" writes (PLT-R1204) and the latency histograms.
public struct ReportDisplay: Sendable, Hashable {
    public let information: String
    public let copyPreview: String
    public let histograms: [LatencyHistogram]

    public init(report: DiagnosticsReport, language: InterfaceLanguage) {
        information = DiagnosticsRenderer.plainText(report, language: language)
        copyPreview = ReportPreviewFormat.copiedBlock.text(report)
        histograms = LatencyHistograms.make(report.latency.metrics)
    }
}
