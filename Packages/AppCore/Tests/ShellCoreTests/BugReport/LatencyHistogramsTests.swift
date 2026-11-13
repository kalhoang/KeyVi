// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1201 "latency histograms" in the Diagnostics window: one histogram per 02-platform.md 8.1 metric of the
// report, bins from the first to the last non-empty bucket with upper bounds that agree with the report's
// percentiles, and locale-aware labels.

import AppModel
import Diagnostics
import Foundation
import Testing

@testable import ShellCore

@Suite struct LatencyHistogramsTests {
    static func snapshot(_ counts: [Int: UInt64]) -> HistogramSnapshot {
        var buckets = HistogramSnapshot.empty.buckets
        for (index, count) in counts { buckets[index] = count }
        return HistogramSnapshot(buckets: buckets)
    }

    static func metrics(t2: HistogramSnapshot = .empty, t6: HistogramSnapshot = .empty) -> MetricsSnapshot {
        MetricsSnapshot(
            callbackDuration: .empty, decideToPosted: t2, decideToPostedWithAX: .empty, echoRoundTrip: .empty,
            heldWait: .empty, focusRefresh: t6, flushes: 0, tapTimeouts: 0, fallbackActivations: 0, echoLosses: 0,
            watchdogTrips: 0, lostWhilePostingBroken: 0)
    }

    @Test func oneHistogramPerMetricInReportOrder() {
        let histograms = LatencyHistograms.make(Self.metrics())
        #expect(histograms.map(\.metric) == LatencyMetric.allCases)
        #expect(LatencyMetric.allCases.map(\.rawValue) == ["t1", "t2", "t3", "echo", "t5", "t6"])
        #expect(histograms.allSatisfy { $0.samples == 0 && $0.bins.isEmpty })
    }

    @Test func everyMetricHasItsOwnTitleAndIdentity() throws {
        let titles = LatencyMetric.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let english = Localizer(language: .english, appBundle: app.bundle)
        for metric in LatencyMetric.allCases where metric != .echo {
            #expect(english.string(metric.title).hasPrefix(metric.rawValue.uppercased() + ":"))
        }
        #expect(LatencyHistograms.make(Self.metrics()).map(\.id) == LatencyMetric.allCases)
    }

    @Test func metricsReadTheirOwnSnapshot() {
        let t2 = Self.snapshot([10: 3])
        let t6 = Self.snapshot([20: 5])
        let histograms = LatencyHistograms.make(Self.metrics(t2: t2, t6: t6))
        #expect(histograms[1].samples == 3 && histograms[5].samples == 5)
        #expect(histograms.filter { $0.samples == 0 }.map(\.metric) == [.t1, .t3, .echo, .t5])
    }

    @Test func binsSpanTheNonEmptyBucketsAndKeepEveryCount() throws {
        let snapshot = Self.snapshot([10: 4, 12: 8, 14: 2])
        let histogram = try #require(LatencyHistograms.make(Self.metrics(t2: snapshot)).first { $0.metric == .t2 })
        #expect(histogram.bins.map(\.count) == [4, 0, 8, 0, 2])
        #expect(histogram.bins.reduce(0) { $0 + $1.count } == snapshot.count)
        #expect(histogram.bins.map(\.fraction) == [0.5, 0, 1, 0, 0.25])
        // Upper bounds increase and agree with the percentile the report prints for the same samples.
        let bounds = histogram.bins.map(\.upperBoundNanoseconds)
        #expect(zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 })
        #expect(histogram.bins[2].upperBoundNanoseconds == Self.snapshot([12: 1]).percentile(1))
        #expect(histogram.bins.last?.upperBoundNanoseconds == snapshot.percentile(1))
        #expect(histogram.bins.first?.upperBoundNanoseconds == snapshot.percentile(0))
    }

    @Test func labelsUseMicrosecondsAndMillisecondsInTheUsersLocale() {
        let english = Locale(identifier: "en_US")
        let vietnamese = Locale(identifier: "vi_VN")
        #expect(LatencyHistograms.label(nanoseconds: 511, locale: english) == "511 ns")
        #expect(LatencyHistograms.label(nanoseconds: 1_023, locale: english) == "1 µs")
        #expect(LatencyHistograms.label(nanoseconds: 16_383, locale: english) == "16 µs")
        #expect(LatencyHistograms.label(nanoseconds: 2_097_151, locale: english) == "2.1 ms")
        #expect(LatencyHistograms.label(nanoseconds: 2_097_151, locale: vietnamese) == "2,1 ms")
        #expect(LatencyHistograms.label(nanoseconds: 4_294_967_295, locale: english) == "4.3 s")
        #expect(LatencyHistograms.label(nanoseconds: UInt64.max, locale: english) == "∞")
    }
}
