// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `compat-harness bench` (PLT-R821, PLT-R822, QA-R14, ADR 0502): measures the self-hosted subset of the
// 02-platform.md 8.1 gates, five runs by default, and writes the median in the benchmark `formatVersion` 1
// format that scripts/bench-compare.sh reads. Every platform metric is `calibrated: false` and its `budget`
// is the "Gate" column. Measurement goes through `PlatformMetricSource`; the live source (CompatHarness/Live)
// samples the app under test with `proc_pid_rusage` and needs the self-hosted runner.

public import Foundation
public import RealtimeSupport

public struct PlatformMetric: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        /// Measured from outside the app (CPU time, footprint, harness timing).
        case harness
        /// Read from the app's own histograms (PLT-R801); needs an export the runner can read (W2-E2).
        case appHistogram
    }

    /// Metric name in the result file, `<8.1 ID>.<statistic>`.
    public var name: String
    public var unit: String
    /// 8.1 "Gate" column, in `unit`.
    public var gate: Double
    public var source: Source
    public var definition: String
}

/// The gated 8.1 metrics `bench` covers. T1 is a hosted pipeline benchmark (PLT-R820); M2 is gated by `soak`
/// (8 hours of typing) and S1 by the launch test, so they are not part of this file.
public enum PlatformGates {
    public static let metrics: [PlatformMetric] = [
        PlatformMetric(
            name: "T2.p99", unit: "ms", gate: 3, source: .appHistogram,
            definition: "callback entry to the last CGEventPost of a job, default strategy"),
        PlatformMetric(
            name: "T3.p99", unit: "ms", gate: 15, source: .appHistogram,
            definition: "decide to posted with axSelection, including the AX read"),
        PlatformMetric(
            name: "T4.p99", unit: "ms", gate: 10, source: .harness,
            definition: "probe text-view update of an edit minus the pass-through baseline"),
        PlatformMetric(
            name: "T5.flushes", unit: "count", gate: 0, source: .appHistogram,
            definition: "held-event flushes in the normal profile"),
        PlatformMetric(
            name: "T6.p95", unit: "ms", gate: 60, source: .appHistogram,
            definition: "AX notification to focus snapshot published"),
        PlatformMetric(
            name: "C1.cpuPercent", unit: "%", gate: 0.3, source: .harness,
            definition: "average CPU of one core, 5 minutes idle, menu closed"),
        PlatformMetric(
            name: "C2.cpuPercent", unit: "%", gate: 3, source: .harness,
            definition: "average CPU of one core while typing 10 keys per second for 5 minutes"),
        PlatformMetric(
            name: "M1.footprintMB", unit: "MB", gate: 50, source: .harness,
            definition: "phys_footprint 10 minutes after launch, windows closed"),
    ]

    public static func metric(named name: String) -> PlatformMetric? { metrics.first { $0.name == name } }
}

/// ADR 0502 result document. `placeholder` marks values nobody measured yet (the committed baseline until the
/// runner exists); bench-compare ignores keys it does not know.
public struct BenchmarkDocument: Sendable, Hashable, Codable {
    public struct Calibration: Sendable, Hashable, Codable {
        public var name: String
        public var nanoseconds: Double
    }

    public struct Metric: Sendable, Hashable, Codable {
        public var value: Double
        public var unit: String
        public var budget: Double?
        public var calibrated: Bool?
        public var placeholder: Bool?
    }

    public var formatVersion: Int
    public var benchmark: String
    public var runs: Int?
    public var calibration: Calibration
    public var referenceCalibration: Calibration?
    public var metrics: [String: Metric]
    public var placeholder: Bool?
    public var note: String?

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// Median per metric and of the calibration over several runs (QA-R14).
    public static func median(of runs: [BenchmarkDocument]) -> BenchmarkDocument? {
        guard let first = runs.first else { return nil }
        var metrics: [String: Metric] = [:]
        for name in Set(runs.flatMap(\.metrics.keys)) {
            let entries = runs.compactMap { $0.metrics[name] }
            var metric = entries[0]
            metric.value = Self.median(entries.map(\.value))
            metrics[name] = metric
        }
        var result = first
        result.runs = runs.count
        result.calibration.nanoseconds = median(runs.map(\.calibration.nanoseconds))
        result.metrics = metrics
        return result
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

public protocol PlatformMetricSource: Sendable {
    /// One measurement of `metric` in its unit. Throws when the metric cannot be measured on this machine.
    func measure(_ metric: PlatformMetric) async throws -> Double
}

public struct PlatformBenchmarkReport: Sendable, Hashable {
    public var median: BenchmarkDocument
    public var perRun: [BenchmarkDocument]
    /// Metrics that could not be measured, with the reason.
    public var unmeasured: [String: String]
}

public struct PlatformBenchmarkRunner: Sendable {
    public static let calibrationName = "platform-reference-loop"
    private let source: any PlatformMetricSource
    private let clock: any MonotonicClock

    public init(source: any PlatformMetricSource, clock: any MonotonicClock) {
        self.source = source
        self.clock = clock
    }

    public func run(metrics: [PlatformMetric], runs: Int) async -> PlatformBenchmarkReport {
        var perRun: [BenchmarkDocument] = []
        var unmeasured: [String: String] = [:]
        for _ in 0..<max(1, runs) {
            var values: [String: BenchmarkDocument.Metric] = [:]
            for metric in metrics where unmeasured[metric.name] == nil {
                do {
                    let value = try await source.measure(metric)
                    values[metric.name] = .init(value: value, unit: metric.unit, budget: metric.gate, calibrated: false)
                } catch {
                    unmeasured[metric.name] = String(describing: error)
                }
            }
            let calibration = BenchmarkDocument.Calibration(name: Self.calibrationName, nanoseconds: calibrate())
            perRun.append(
                BenchmarkDocument(
                    formatVersion: 1, benchmark: "platform", runs: 1, calibration: calibration, metrics: values))
        }
        for name in unmeasured.keys { for index in perRun.indices { perRun[index].metrics[name] = nil } }
        let median = BenchmarkDocument.median(of: perRun) ?? perRun[0]
        return PlatformBenchmarkReport(median: median, perRun: perRun, unmeasured: unmeasured)
    }

    /// Fixed reference workload (ADR 0502 `calibration`); informational because every metric is uncalibrated.
    /// At least 1 ns, since bench-compare rejects a non-positive calibration.
    func calibrate() -> Double {
        let start = clock.now().nanoseconds
        // Seeded from the clock and kept alive, so the optimiser can neither fold nor drop the loop.
        var state = start | 1
        for _ in 0..<200_000 { state = (state ^ (state << 13)) &* 0x2545_F491_4F6C_DD1D }
        withExtendedLifetime(state) {}
        return Double(max(1, clock.now().nanoseconds &- start))
    }
}
