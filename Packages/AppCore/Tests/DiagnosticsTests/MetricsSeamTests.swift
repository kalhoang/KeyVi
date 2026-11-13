// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Skeleton seam tests (ADR 0313): keep green; owners may extend.
import AppModel
import Foundation
import RealtimeSupport
import Testing
@testable import Diagnostics

@Suite struct Log2HistogramTests {
    @Test func bucketsAreLog2() {
        let histogram = Log2Histogram()
        for value: UInt64 in [0, 1, 2, 3, 4, 1_000, 1_023, 1_024] { histogram.record(nanoseconds: value) }
        let buckets = histogram.snapshot().buckets
        #expect(buckets.count == 64)
        #expect(buckets[0] == 2)  // 0 and 1
        #expect(buckets[1] == 2)  // 2 and 3
        #expect(buckets[2] == 1)  // 4
        #expect(buckets[9] == 2)  // 1_000, 1_023
        #expect(buckets[10] == 1)  // 1_024
        histogram.record(nanoseconds: .max)
        #expect(histogram.snapshot().buckets[63] == 1)
    }

    @Test func percentileReturnsBucketUpperBound() {
        let histogram = Log2Histogram()
        for _ in 0..<99 { histogram.record(nanoseconds: 10_000) }  // bucket 13: 8_192...16_383
        histogram.record(nanoseconds: 1_000_000)  // bucket 19
        let snapshot = histogram.snapshot()
        #expect(snapshot.percentile(0.5) == 16_383)
        #expect(snapshot.percentile(0.99) == 16_383)
        #expect(snapshot.percentile(1.0) == 1_048_575)
        #expect(HistogramSnapshot.empty.percentile(0.5) == nil)
        #expect(snapshot.percentile(1.5) == nil)
    }
}

@Suite struct PlatformMetricsTests {
    @Test func snapshotCarriesCounters() {
        let metrics = PlatformMetrics()
        metrics.flushes.increment()
        metrics.echoLosses.increment(by: 3)
        metrics.lostWhilePostingBroken.increment(by: 2)
        metrics.callbackDuration.record(nanoseconds: 15_000)
        let snapshot = metrics.snapshot()
        #expect(snapshot.flushes == 1)
        #expect(snapshot.echoLosses == 3)
        #expect(snapshot.lostWhilePostingBroken == 2)
        #expect(snapshot.callbackDuration.count == 1)
    }

    @Test func perBundleHistogramsEvictLeastRecentlyUsed() throws {
        let histograms = PerBundleHistograms(capacity: 2)
        let a = try #require(BundleKey(rawValue: "com.example.a"))
        let b = try #require(BundleKey(rawValue: "com.example.b"))
        let c = try #require(BundleKey(rawValue: "com.example.c"))
        histograms.record(a, nanoseconds: 1)
        histograms.record(b, nanoseconds: 1)
        histograms.record(a, nanoseconds: 1)  // a is now most recent
        histograms.record(c, nanoseconds: 1)  // evicts b
        let snapshot = histograms.snapshot()
        #expect(Set(snapshot.keys) == [a, c])
        #expect(snapshot[a]?.count == 2)
    }
}

@Suite struct HealthEventLogTests {
    @Test func ringKeepsNewestAndCountsWithinWindow() {
        let log = HealthEventLog(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<5 {
            log.record(HealthEvent(kind: offset.isMultiple(of: 2) ? .tapTimeout : .flush, at: start + Double(offset)))
        }
        let recent = log.recent(limit: 10)
        #expect(recent.map(\.at) == [start + 2, start + 3, start + 4])
        #expect(log.recent(limit: 1).map(\.at) == [start + 4])
        #expect(log.count(of: .tapTimeout, within: 600, now: start + 4) == 2)
        #expect(log.count(of: .tapTimeout, within: 1, now: start + 4) == 1)
    }
}

@Suite struct TapLogRingTests {
    @Test func dropsAndCountsWhenFull() {
        let ring = TapLogRing(capacity: 3)  // rounded to 4
        for index in 0..<6 { ring.push(TapLogRecord(code: .flushRequested, at: .zero, a: UInt64(index))) }
        var drained: [UInt64] = []
        ring.drain { drained.append($0.a) }
        #expect(drained == [0, 1, 2, 3])
        #expect(ring.droppedCount == 2)
    }
}
