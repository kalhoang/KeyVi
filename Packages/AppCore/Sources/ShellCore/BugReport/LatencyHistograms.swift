// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The latency histograms of the Diagnostics window (PLT-R1201): one per 02-platform.md 8.1 metric that the report
// carries (PLT-R801), drawn from the report's own histogram snapshots, so the window and the copied percentiles
// always describe the same samples. Content-free: bucket bounds and counts only.

public import Diagnostics
public import Foundation

/// The report's latency metrics in report order; raw values are the ADR 0501 `latency.<metric>` key segments.
public enum LatencyMetric: String, Sendable, Hashable, CaseIterable {
    case t1, t2, t3, echo, t5, t6

    public func histogram(in metrics: MetricsSnapshot) -> HistogramSnapshot {
        switch self {
        case .t1: metrics.callbackDuration
        case .t2: metrics.decideToPosted
        case .t3: metrics.decideToPostedWithAX
        case .echo: metrics.echoRoundTrip
        case .t5: metrics.heldWait
        case .t6: metrics.focusRefresh
        }
    }

    /// Name and plain definition of the metric (02-platform.md 8.1).
    public var title: DiagnosticsText {
        switch self {
        case .t1: .latencyT1
        case .t2: .latencyT2
        case .t3: .latencyT3
        case .echo: .latencyEcho
        case .t5: .latencyT5
        case .t6: .latencyT6
        }
    }
}

public struct LatencyHistogram: Sendable, Hashable, Identifiable {
    public struct Bin: Sendable, Hashable {
        /// Every sample of the bin took at most this long; `UInt64.max` for the open-ended last bucket.
        public var upperBoundNanoseconds: UInt64
        public var count: UInt64
        /// `count` relative to the fullest bin of this histogram (0...1), for the bar length.
        public var fraction: Double
    }

    public var metric: LatencyMetric
    public var samples: UInt64
    /// From the first to the last non-empty bucket, empty buckets in between included; empty without samples.
    public var bins: [Bin]
    public var id: LatencyMetric { metric }
}

public enum LatencyHistograms {
    public static func make(_ metrics: MetricsSnapshot) -> [LatencyHistogram] {
        LatencyMetric.allCases.map { metric in
            let snapshot = metric.histogram(in: metrics)
            return LatencyHistogram(metric: metric, samples: snapshot.count, bins: bins(snapshot))
        }
    }

    static func bins(_ snapshot: HistogramSnapshot) -> [LatencyHistogram.Bin] {
        let buckets = snapshot.buckets
        guard let first = buckets.firstIndex(where: { $0 > 0 }), let last = buckets.lastIndex(where: { $0 > 0 }),
            let fullest = buckets.max(), fullest > 0
        else { return [] }
        return (first...last).map { index in
            LatencyHistogram.Bin(
                upperBoundNanoseconds: upperBound(ofBucket: index, bucketCount: buckets.count), count: buckets[index],
                fraction: Double(buckets[index]) / Double(fullest))
        }
    }

    /// The upper bound of a bucket as the snapshot's own `percentile` reports it, so the bins follow whatever
    /// bucket layout `HistogramSnapshot` uses and agree with the percentiles of the copied report.
    static func upperBound(ofBucket index: Int, bucketCount: Int) -> UInt64 {
        var buckets = [UInt64](repeating: 0, count: bucketCount)
        buckets[index] = 1
        return HistogramSnapshot(buckets: buckets).percentile(1) ?? UInt64.max
    }

    /// A duration with its unit, at most two significant digits, in the interface locale: `511 ns`, `16 µs`,
    /// `2,1 ms` (Vietnamese) or `2.1 ms` (English), `4.3 s`; `∞` for the open-ended bucket.
    public static func label(nanoseconds: UInt64, locale: Locale) -> String {
        guard nanoseconds != UInt64.max else { return "∞" }
        let units: [(divisor: Double, symbol: String)] = [(1e9, "s"), (1e6, "ms"), (1e3, "µs")]
        let value = Double(nanoseconds)
        guard let unit = units.first(where: { value >= $0.divisor }) else { return String(nanoseconds) + " ns" }
        let number = (value / unit.divisor).formatted(
            FloatingPointFormatStyle<Double>(locale: locale).precision(.significantDigits(1...2)))
        return number + " " + unit.symbol
    }
}
