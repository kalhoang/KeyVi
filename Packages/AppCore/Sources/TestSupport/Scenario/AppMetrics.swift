// SPDX-License-Identifier: LicenseRef-App-Pending
//
// T2, T3, T5 and T6 from the app's own PLT-R801 histograms and T4 from its built-in latency probe (PLT-R810),
// both read through the integration hooks (ADR 0502). One run: reset the app's metrics, type the measured
// workload into TestHost (profile `bench-workload`), read the snapshot once for all histogram metrics; then run the
// latency probe once for T4. Every other metric (C1, C2, M1) goes to the process-sampling source.

public import Diagnostics
internal import Foundation

/// Value of a percentile from log2 buckets, interpolated linearly inside the bucket that holds it. The bucket
/// upper bound alone overstates a p99 by up to a factor of two, which would fail the 3 ms T2 gate for a real p99
/// of 2.2 ms (bucket 2.1 to 4.2 ms). Still an estimate: the true value lies in the same bucket.
public enum HistogramPercentile {
    public static func nanoseconds(_ snapshot: HistogramSnapshot, _ fraction: Double) -> Double? {
        let total = snapshot.count
        guard total > 0, (0.0...1.0).contains(fraction) else { return nil }
        let rank = max(1, (Double(total) * fraction).rounded(.up))
        var before = 0.0
        for (index, count) in snapshot.buckets.enumerated() where count > 0 {
            let inBucket = Double(count)
            if before + inBucket >= rank {
                let lower = index == 0 ? 0 : pow(2.0, Double(index))
                let upper = pow(2.0, Double(index + 1))
                return lower + (upper - lower) * (rank - before) / inBucket
            }
            before += inBucket
        }
        return nil
    }
}

/// The measured typing workload: words into the main field, the second-window field and the address bar, with a
/// focus change (TestHost Command+1, Command+2, Command+3) every few words, so T2 (default strategy), T3
/// (axSelection on the address bar under profile `bench-workload`) and T6 (focus refresh) all get samples.
public enum BenchWorkload {
    /// App profile the workload runs under (compat/scenarios/profiles/bench-workload.json).
    public static let profileID = "bench-workload"
    /// Focus shortcuts of TestHost's Window menu.
    public static let focusKeys = ["command+1", "command+2", "command+3"]
    public static let wordsPerFocus = 5

    /// About `keystrokes` keys of Telex words from the soak corpus, deterministic for `seed`.
    public static func keys(keystrokes: Int, seed: UInt64) -> [String] {
        var generator = SeededGenerator(seed: seed)
        var keys: [String] = []
        var words = 0
        while keys.count < keystrokes {
            if words % wordsPerFocus == 0 { keys.append(focusKeys[(words / wordsPerFocus) % focusKeys.count]) }
            let word = SoakCorpus.words[Int(generator.next() % UInt64(SoakCorpus.words.count))]
            keys += word.keys.map(String.init) + ["space"]
            words += 1
        }
        return keys
    }
}

public struct AppMetricSource: PlatformMetricSource {
    /// Types the workload (live: launch TestHost, apply `bench-workload`, PhysicalKeyboardDriver at normal timing).
    public typealias Workload = @Sendable () async throws -> Void

    private let hooks: any AppHookClient
    private let workload: Workload
    private let processSampling: any PlatformMetricSource

    public init(hooks: any AppHookClient, workload: @escaping Workload, processSampling: any PlatformMetricSource) {
        self.hooks = hooks
        self.workload = workload
        self.processSampling = processSampling
    }

    public func measure(_ metric: PlatformMetric) async throws -> Double {
        guard let result = await measure([metric])[metric.name] else { throw PlatformMetricUnavailable(reason: "") }
        return try result.get()
    }

    public func measure(_ metrics: [PlatformMetric]) async -> [String: Result<Double, any Error>] {
        var results = await processSampling.measure(metrics.filter { $0.source == .harness })
        let histogram = metrics.filter { $0.source == .appHistogram }
        if !histogram.isEmpty {
            switch await Result(catching: { try await workloadSnapshot() }) {
            case .success(let snapshot):
                for metric in histogram { results[metric.name] = Self.value(metric, from: snapshot) }
            case .failure(let error): for metric in histogram { results[metric.name] = .failure(error) }
            }
        }
        for metric in metrics where metric.source == .latencyProbe {
            results[metric.name] = await Result { try await self.probeT4() }
        }
        for metric in metrics where metric.source == .soak {
            results[metric.name] = .failure(PlatformMetricUnavailable(reason: "measured by soak"))
        }
        return results
    }

    private func workloadSnapshot() async throws -> MetricsSnapshot {
        try await hooks.resetMetrics()
        try await workload()
        return try await hooks.state().metrics
    }

    private func probeT4() async throws -> Double {
        let result = try await hooks.latencyProbe(.normal)
        guard let normal = result.results.first(where: { $0.profile == .normal }) else {
            throw AppHookError.missingPayload(command: "latencyProbe")
        }
        return Double(normal.endToEndDeltaP99Microseconds) / 1_000
    }

    /// 8.1 statistic of a histogram metric, in its unit.
    static func value(_ metric: PlatformMetric, from snapshot: MetricsSnapshot) -> Result<Double, any Error> {
        let histogram: (HistogramSnapshot, Double)? =
            switch metric.name {
            case "T2.p99": (snapshot.decideToPosted, 0.99)
            case "T3.p99": (snapshot.decideToPostedWithAX, 0.99)
            case "T6.p95": (snapshot.focusRefresh, 0.95)
            default: nil
            }
        if metric.name == "T5.flushes" { return .success(Double(snapshot.flushes)) }
        guard let (buckets, fraction) = histogram else {
            return .failure(PlatformMetricUnavailable(reason: "no app histogram for " + metric.name))
        }
        guard let nanoseconds = HistogramPercentile.nanoseconds(buckets, fraction) else {
            return .failure(AppMetricError.noSamples(metric.name))
        }
        return .success(nanoseconds / 1_000_000)
    }
}

public enum AppMetricError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The workload produced no sample for this histogram (for example no axSelection edit for T3).
    case noSamples(String)
    public var description: String {
        switch self {
        case .noSamples(let metric): "the workload produced no samples for " + metric
        }
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
