// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Latency probe arithmetic (PLT-R810, 02-platform.md 8.1 T2 and T4): pacing, sample correlation and
// percentiles. Pure functions over synthetic timestamps, tested with `ManualClock`.

internal import AppModel
public import Diagnostics
internal import Foundation
internal import Injection
public import RealtimeSupport

/// One probe key: when the driver posted it and when the probe window showed its result (nil when no change
/// could be matched to it).
public struct LatencyProbeSample: Sendable, Hashable {
    public var posted: MonotonicInstant
    public var changed: MonotonicInstant?

    public init(posted: MonotonicInstant, changed: MonotonicInstant?) {
        self.posted = posted
        self.changed = changed
    }

    /// Text-change latency in nanoseconds.
    public var latencyNanoseconds: UInt64? { changed.map { $0.nanoseconds(since: posted) } }
}

extension LatencyProbeResult.Profile {
    /// PLT-R810 spacing between keys: normal 120 ms, fast 40 ms, burst 5 ms.
    public var keyInterval: Duration {
        switch self {
        case .normal: .milliseconds(120)
        case .fast: .milliseconds(40)
        case .burst: .milliseconds(5)
        }
    }
}

enum LatencyProbeMath {
    /// In-order matching (the window applies keys first in, first out): the k-th change at or after its key's
    /// post belongs to the k-th delivered key. Changes older than the key they would match are leftovers and
    /// skipped; an undelivered key consumes no change. Keys left without a change have none (nil).
    static func correlate(_ keys: [LatencyProbePostedKey], changes: [MonotonicInstant]) -> [LatencyProbeSample] {
        let sorted = changes.sorted()
        var next = sorted.startIndex
        return keys.map { key in
            guard key.delivered else { return LatencyProbeSample(posted: key.instant, changed: nil) }
            while next < sorted.endIndex, sorted[next] < key.instant { next += 1 }
            guard next < sorted.endIndex else { return LatencyProbeSample(posted: key.instant, changed: nil) }
            defer { next += 1 }
            return LatencyProbeSample(posted: key.instant, changed: sorted[next])
        }
    }

    static func result(
        profile: LatencyProbeResult.Profile, baseline: [LatencyProbeSample], measured: [LatencyProbeSample],
        decideToPosted: HistogramSnapshot
    ) -> LatencyProbeResult.ProfileResult {
        let base = baseline.compactMap(\.latencyNanoseconds)
        let edits = measured.compactMap(\.latencyNanoseconds)
        return LatencyProbeResult.ProfileResult(
            profile: profile,
            decideToPostedP50Microseconds: (decideToPosted.precisePercentile(0.5) ?? 0) / 1_000,
            decideToPostedP99Microseconds: (decideToPosted.precisePercentile(0.99) ?? 0) / 1_000,
            endToEndDeltaP50Microseconds: delta(edits, base, 0.5) / 1_000,
            endToEndDeltaP99Microseconds: delta(edits, base, 0.99) / 1_000,
            samples: edits.count)
    }

    /// Measured percentile minus baseline percentile, saturating at zero; zero without measured samples.
    static func delta(_ measured: [UInt64], _ baseline: [UInt64], _ fraction: Double) -> UInt64 {
        guard let edit = percentile(measured, fraction) else { return 0 }
        let base = percentile(baseline, fraction) ?? 0
        return edit > base ? edit - base : 0
    }

    /// Nearest-rank percentile; nil for no values.
    static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    /// Per-bucket difference of two snapshots of the same histogram (the run's own samples), sub-buckets
    /// included when both snapshots have the same layout.
    static func difference(_ after: HistogramSnapshot, _ before: HistogramSnapshot) -> HistogramSnapshot {
        var subBuckets: SubBucketSnapshot?
        if let later = after.subBuckets, let earlier = before.subBuckets, later.segments == earlier.segments {
            subBuckets = SubBucketSnapshot(segments: later.segments, counts: subtract(later.counts, earlier.counts))
        }
        return HistogramSnapshot(buckets: subtract(after.buckets, before.buckets), subBuckets: subBuckets)
    }

    private static func subtract(_ after: [UInt64], _ before: [UInt64]) -> [UInt64] {
        after.indices.map { index in
            let earlier = index < before.count ? before[index] : 0
            return after[index] > earlier ? after[index] - earlier : 0
        }
    }

    static func microseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let total = components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
        return total > 0 ? UInt64(total) : 0
    }
}

extension LatencyProbeDriver {
    /// Dedicated thread: absolute-deadline pacing on `clock`, one keyDown and keyUp per key, then the settle
    /// window. Returns the post instants of the keyDowns. Once `shouldContinue` returns false the loop ends at
    /// once: no further key is posted and there is no settle wait.
    func postAll(
        _ keys: [KeyCode], every interval: Duration, shouldContinue: @Sendable () -> Bool = { true }
    ) -> [LatencyProbePostedKey] {
        let start = clock.now()
        let step = LatencyProbeMath.microseconds(interval)
        var posted: [LatencyProbePostedKey] = []
        posted.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
            clock.sleep(until: start.advanced(byMicroseconds: step * UInt64(index)))
            guard shouldContinue() else { return posted }
            let instant = clock.now()
            let delivered = post(key, down: true)
            if delivered { _ = post(key, down: false) }
            posted.append(LatencyProbePostedKey(instant: instant, delivered: delivered))
        }
        if let last = posted.last {
            clock.sleep(until: last.instant.advanced(byMicroseconds: LatencyProbeMath.microseconds(settle)))
        }
        return posted
    }

    /// Physical-like: no Unicode payload (the system derives it from the layout), no flags. A failed creation
    /// loses one sample (its change stays nil); the probe never retries or blocks.
    private func post(_ key: KeyCode, down: Bool) -> Bool {
        let event = SyntheticKeyEvent(keyCode: key, isKeyDown: down, flags: 0, unicode: .empty)
        do {
            try poster.post(event, userData: marker.userData(sequence: sequence.next(), probe: true))
            return true
        } catch {
            return false
        }
    }
}

/// Runs blocking work (absolute-deadline sleeps, AX calls) on its own thread so no Swift concurrency thread or
/// the main thread blocks while a probe types.
enum DedicatedThread {
    static func run<Value: Sendable>(name: String, _ body: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.name = name
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
