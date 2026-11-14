// SPDX-License-Identifier: GPL-3.0-or-later
//
// Health events the Diagnostics window and the copied report explain in plain words (PLT-R1201 "a plain
// explanation", PRD-R62): a label and a sentence in the interface language, the app name an argument. The other
// kinds stay summary lines for maintainers.

public import Foundation

public enum HealthNotice: String, Sendable, Hashable, CaseIterable {
    /// PLT-R397B: short secure-input episodes kept ending while the user typed, so keys may not have reached the app.
    case secureInputBursts

    /// An event explains the present for the report's 24-hour window (the tap counters' window, PLT-R1202).
    public static let window: TimeInterval = 24 * 60 * 60

    public init?(kind: HealthEvent.Kind) {
        switch kind {
        case .secureInputBursts: self = .secureInputBursts
        default: return nil
        }
    }

    /// The notices `report` calls for: a kind with an explanation recorded within `window` before the report was
    /// generated, each once, in declaration order.
    public static func notices(in report: DiagnosticsReport) -> [HealthNotice] {
        let since = report.generatedAt.addingTimeInterval(-window)
        let recent = report.healthEvents.filter { $0.at > since && $0.at <= report.generatedAt }
        let kinds = Set(recent.compactMap { HealthNotice(kind: $0.kind) })
        return allCases.filter(kinds.contains)
    }
}

/// A notice as one surface shows it.
public struct HealthNoticeText: Sendable, Hashable {
    public var label: String
    public var explanation: String

    public init(label: String, explanation: String) {
        self.label = label
        self.explanation = explanation
    }
}
