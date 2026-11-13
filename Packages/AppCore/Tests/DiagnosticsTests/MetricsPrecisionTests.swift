// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W3-A: gate-aligned sub-buckets of the decide-to-posted histograms (02-platform.md 8.1 T2 and T3; the W1-A
// precision request in integration-notes.md "WAVE 2b") and `PlatformMetrics.reset()` for the integration hooks'
// `resetMetrics` (ADR 0502). The recording path stays lock-free and allocation-free (HotPathAllocationTests).

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import Diagnostics

@Suite struct LatencySubBucketTests {
    /// Reference layout walk from `segments`: (start + i * width, start + (i + 1) * width].
    private func referenceIndex(_ nanoseconds: UInt64) -> Int? {
        var start: UInt64 = 0
        var offset = 0
        for segment in LatencySubBuckets.segments {
            if nanoseconds <= segment.upToNanoseconds {
                let position = nanoseconds <= start ? 0 : (nanoseconds - start - 1) / segment.widthNanoseconds
                return offset + Int(position)
            }
            offset += Int((segment.upToNanoseconds - start) / segment.widthNanoseconds)
            start = segment.upToNanoseconds
        }
        return nil
    }

    @Test func indexMatchesTheDeclaredSegments() {
        var values: [UInt64] = [0, 1, 9_999, 10_000, 10_001, 25_000_000, 25_000_001, .max]
        for segment in LatencySubBuckets.segments {
            let edge = segment.upToNanoseconds
            values += [edge - 1, edge, edge + 1, edge - segment.widthNanoseconds, edge - segment.widthNanoseconds + 1]
        }
        values += stride(from: UInt64(0), through: 26_000_000, by: 7_919).map { $0 }
        for value in values {
            #expect(LatencySubBuckets.index(nanoseconds: value) == referenceIndex(value), "\(value)")
        }
        let snapshot = SubBucketSnapshot(
            segments: LatencySubBuckets.segments, counts: Array(repeating: 0, count: LatencySubBuckets.count))
        #expect(snapshot.isConsistent && snapshot.upperNanoseconds == LatencySubBuckets.upperNanoseconds)
    }

    /// Every 8.1 value up to 25 ms is a bucket edge: T2 0.5, 2 and 3 ms, T3 2, 8 and 15 ms, T4 10 ms, Intel 4.5
    /// and 22.5 ms. A value at the gate and the next nanosecond land in different buckets.
    @Test func everyGateIsABucketEdge() throws {
        for milliseconds in [0.5, 2, 3, 4.5, 8, 10, 15, 22.5] {
            let gate = UInt64(milliseconds * 1_000_000)
            let at = try #require(LatencySubBuckets.index(nanoseconds: gate))
            let above = try #require(LatencySubBuckets.index(nanoseconds: gate + 1))
            #expect(above == at + 1, "\(milliseconds) ms")
            let histogram = Log2Histogram(subBuckets: true)
            histogram.record(nanoseconds: gate)
            #expect(histogram.snapshot().precisePercentile(0.99) == gate)
        }
    }

    /// The T2 decision at 3 ms is exact: a p99 of exactly 3 ms reads 3 ms, one nanosecond more reads above it.
    /// The log2 percentile could only say "somewhere below 4.19 ms" for both.
    @Test func t2GateDecisionIsExact() {
        func p99(_ slow: UInt64) -> (precise: UInt64?, log2: UInt64?) {
            let histogram = Log2Histogram(subBuckets: true)
            for _ in 0..<99 { histogram.record(nanoseconds: 800_000) }
            histogram.record(nanoseconds: slow)
            histogram.record(nanoseconds: slow)
            let snapshot = histogram.snapshot()
            return (snapshot.precisePercentile(0.99), snapshot.percentile(0.99))
        }
        #expect(p99(3_000_000).precise == 3_000_000)
        #expect(p99(3_000_001).precise == 3_050_000)
        #expect(p99(3_000_000).log2 == p99(3_000_001).log2)
        #expect(p99(30_000_000).precise == p99(30_000_000).log2)  // above 25 ms: log2
    }

    @Test func plainHistogramsHaveNoSubBuckets() {
        let histogram = Log2Histogram()
        histogram.record(nanoseconds: 3_000_000)
        #expect(histogram.snapshot().subBuckets == nil)
        #expect(histogram.snapshot().precisePercentile(0.5) == histogram.snapshot().percentile(0.5))
        let metrics = PlatformMetrics().snapshot()
        #expect(metrics.decideToPosted.subBuckets?.counts.count == LatencySubBuckets.count)
        #expect(metrics.decideToPostedWithAX.subBuckets != nil)
        #expect(metrics.callbackDuration.subBuckets == nil && metrics.focusRefresh.subBuckets == nil)
    }

    @Test func inconsistentLayoutsAreIgnored() {
        let good = LatencySubBuckets.Segment(upToNanoseconds: 100, widthNanoseconds: 10)
        let cases: [SubBucketSnapshot] = [
            SubBucketSnapshot(segments: [], counts: []),
            SubBucketSnapshot(segments: [good], counts: [1]),
            SubBucketSnapshot(segments: [.init(upToNanoseconds: 100, widthNanoseconds: 0)], counts: []),
            SubBucketSnapshot(segments: [.init(upToNanoseconds: 100, widthNanoseconds: 30)], counts: [1, 1, 1]),
            SubBucketSnapshot(segments: [good, .init(upToNanoseconds: 50, widthNanoseconds: 10)], counts: []),
            SubBucketSnapshot(segments: [.init(upToNanoseconds: 1 << 40, widthNanoseconds: 1)], counts: [1]),
        ]
        for snapshot in cases {
            #expect(!snapshot.isConsistent)
            #expect(snapshot.position(ofRank: 1) == nil)
        }
        var buckets = HistogramSnapshot.empty.buckets
        buckets[21] = 1
        let snapshot = HistogramSnapshot(buckets: buckets, subBuckets: cases[1])
        #expect(snapshot.precisePercentile(0.5) == snapshot.percentile(0.5))
        let ten = SubBucketSnapshot(segments: [good], counts: Array(repeating: 1, count: 10))
        #expect(ten.position(ofRank: 0) == nil && ten.position(ofRank: 11) == nil)
        #expect(ten.position(ofRank: 10) == .init(lower: 90, upper: 100, before: 9, count: 1))
    }
}

@Suite struct MetricsSnapshotCompatibilityTests {
    /// JSON written before W3-A (log2 buckets only, as the W2-E2 harness and earlier reports have it) still
    /// decodes; histograms without sub-buckets leave the key out, so their JSON is unchanged.
    @Test func olderJSONStillDecodes() throws {
        let buckets = "[" + Array(repeating: "0", count: 63).joined(separator: ",") + ",5]"
        let histogram = #"{"buckets":"# + buckets + "}"
        var fields = ["callbackDuration", "decideToPosted", "decideToPostedWithAX", "echoRoundTrip", "heldWait"]
        fields.append("focusRefresh")
        let histograms = fields.map { "\"\($0)\":" + histogram }.joined(separator: ",")
        let counters = ["flushes", "tapTimeouts", "fallbackActivations", "echoLosses", "watchdogTrips"]
            .map { "\"\($0)\":1" }.joined(separator: ",")
        let json = "{" + histograms + "," + counters + #","lostWhilePostingBroken":2}"#
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        #expect(decoded.decideToPosted.subBuckets == nil && decoded.decideToPosted.count == 5)
        #expect(decoded.lostWhilePostingBroken == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = String(decoding: try encoder.encode(decoded.focusRefresh), as: UTF8.self)
        #expect(plain == histogram)
    }

    @Test func subBucketsRoundTrip() throws {
        let metrics = PlatformMetrics()
        metrics.decideToPosted.record(nanoseconds: 2_999_000)
        metrics.decideToPostedWithAX.record(nanoseconds: 14_000_000)
        let snapshot = metrics.snapshot()
        let decoded = try JSONDecoder().decode(MetricsSnapshot.self, from: try JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.decideToPosted.precisePercentile(0.99) == 3_000_000)
        #expect(decoded.decideToPostedWithAX.precisePercentile(0.99) == 14_000_000)
    }
}

@Suite struct PlatformMetricsResetTests {
    @Test func resetZeroesEveryHistogramAndCounter() throws {
        let metrics = PlatformMetrics()
        let histograms = [
            metrics.callbackDuration, metrics.decideToPosted, metrics.decideToPostedWithAX, metrics.echoRoundTrip,
            metrics.heldWait, metrics.focusRefresh, metrics.probeDecideToPosted,
        ]
        for histogram in histograms { histogram.record(nanoseconds: 2_000_000) }
        let counters = [
            metrics.flushes, metrics.tapTimeouts, metrics.fallbackActivations, metrics.echoLosses,
            metrics.watchdogTrips, metrics.lostWhilePostingBroken,
        ]
        for counter in counters { counter.increment(by: 3) }
        metrics.axCallDurations.record(try #require(BundleKey(rawValue: "com.example.a")), nanoseconds: 5)
        metrics.reset()
        let empty = PlatformMetrics().snapshot()
        #expect(metrics.snapshot() == empty)
        for histogram in histograms {
            #expect(histogram.snapshot().count == 0)
            #expect(histogram.snapshot().subBuckets?.counts.allSatisfy { $0 == 0 } ?? true)
        }
        #expect(counters.allSatisfy { $0.value == 0 })
        #expect(metrics.axCallDurations.snapshot().isEmpty)
        metrics.decideToPosted.record(nanoseconds: 1)
        #expect(metrics.snapshot().decideToPosted.count == 1)
    }

    /// Reset while another thread records (the tap and the worker keep running during `resetMetrics`): no crash,
    /// no torn count, and the values recorded after the last reset are all there. Run under TSan as well.
    @Test func resetIsSafeWhileRecording() async {
        let metrics = PlatformMetrics()
        let stop = Atomic<Bool>(false)
        let recorder = Task.detached {
            var recorded: UInt64 = 0
            while !stop.load(ordering: .relaxed) {
                metrics.decideToPosted.record(nanoseconds: 2_500_000)
                metrics.flushes.increment()
                recorded += 1
            }
            return recorded
        }
        for _ in 0..<200 { metrics.reset() }
        stop.store(true, ordering: .relaxed)
        let recorded = await recorder.value
        let snapshot = metrics.snapshot()
        #expect(snapshot.decideToPosted.count <= recorded && snapshot.flushes <= recorded)
        metrics.reset()
        for _ in 0..<10 { metrics.decideToPosted.record(nanoseconds: 2_500_000) }
        #expect(metrics.snapshot().decideToPosted.count == 10)
        #expect(metrics.snapshot().decideToPosted.subBuckets?.counts.reduce(0, +) == 10)
    }
}
