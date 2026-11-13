// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R822 regression gate for the self-hosted platform metrics: fail when a metric exceeds its 8.1 gate, or
// exceeds the stored baseline (perf/platform-baseline.json, ADR 0502 formatVersion 1) by more than 25 %. Platform
// metrics are never calibrated, so the comparison is direct; scripts/bench-compare.sh applies the same baseline rule
// in CI. Baseline values marked `placeholder` were never measured: they equal the gates until the runner records the
// first real baseline in a perf-baseline PR (QA-R15), and the gate itself still applies.

internal import Foundation

public struct RegressionVerdict: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case ok
        case overGate
        case regression
        /// The baseline has no value for this metric: only the gate applied.
        case noBaseline
    }

    public var metric: String
    public var value: Double
    public var gate: Double
    public var baseline: Double?
    public var baselineIsPlaceholder: Bool
    public var outcome: Outcome
    public var failed: Bool { outcome == .overGate || outcome == .regression }
}

public enum RegressionGate {
    /// PLT-R822.
    public static let thresholdPercent = 25.0
    /// Committed baseline of the platform metrics.
    public static let baselinePath = "perf/platform-baseline.json"

    public static func evaluate(
        _ result: BenchmarkDocument, gates: [PlatformMetric], baseline: BenchmarkDocument?,
        thresholdPercent: Double = thresholdPercent
    ) -> [RegressionVerdict] {
        gates.compactMap { gate in
            guard let value = result.metrics[gate.name]?.value else { return nil }
            let stored = baseline?.metrics[gate.name]
            let placeholder = (stored?.placeholder ?? false) || (baseline?.placeholder ?? false)
            let outcome: RegressionVerdict.Outcome
            if value > gate.gate {
                outcome = .overGate
            } else if let reference = stored?.value {
                // A zero baseline (T5 flushes) has no relative change; the gate decides.
                outcome = reference > 0 && value > reference * (1 + thresholdPercent / 100) ? .regression : .ok
            } else {
                outcome = .noBaseline
            }
            return RegressionVerdict(
                metric: gate.name, value: value, gate: gate.gate, baseline: stored?.value,
                baselineIsPlaceholder: placeholder, outcome: outcome)
        }
    }

    /// One line per verdict for the console.
    public static func describe(_ verdict: RegressionVerdict) -> String {
        let base =
            verdict.baseline.map {
                String(format: ", baseline %.3f", $0) + (verdict.baselineIsPlaceholder ? " (placeholder)" : "")
            } ?? ", no baseline"
        let label: String =
            switch verdict.outcome {
            case .ok, .noBaseline: "ok"
            case .overGate: "OVER GATE"
            case .regression: "REGRESSION (more than \(Int(thresholdPercent)) % above the baseline)"
            }
        return verdict.metric + String(format: " %.3f, gate %.3f", verdict.value, verdict.gate) + base + ": " + label
    }
}
