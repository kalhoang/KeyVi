// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Always-on, content-free, lock-free histograms (PLT-R801): fixed memory, log2 buckets, safe on the tap.
// Implemented in the skeleton because the pipeline and the worker record into them on every event
// (docs/decisions/0313-testability-seams.md); workstream W1-A owns, benchmarks and may optimise them. W3-A added
// the gate-aligned sub-buckets of the decide-to-posted histograms and `PlatformMetrics.reset()` for the
// integration hooks (ADR 0502).

public import AppModel
internal import RealtimeSupport
internal import Synchronization

/// 64 log2 buckets of nanoseconds (bucket i counts values in [2^i, 2^(i+1)); bucket 0 also counts 0), one
/// `Atomic<UInt64>` each. A histogram created with `subBuckets: true` also counts every value up to
/// `LatencySubBuckets.upperNanoseconds` in the fixed linear buckets of `LatencySubBuckets`, so a percentile
/// decision against the 8.1 gates is exact (a log2 bucket from 2.1 to 4.2 ms straddles the 3 ms T2 gate).
public final class Log2Histogram: Sendable {
    public static let bucketCount = 64
    private let buckets = AtomicUInt64Array(count: Log2Histogram.bucketCount)
    private let subBuckets: AtomicUInt64Array?

    public init(subBuckets: Bool = false) {
        self.subBuckets = subBuckets ? AtomicUInt64Array(count: LatencySubBuckets.count) : nil
    }

    /// Lock-free, allocation-free; allowed on the tap thread (PLT-R304). Two relaxed increments at most.
    @inline(__always)
    public func record(nanoseconds: UInt64) {
        let index = nanoseconds == 0 ? 0 : (UInt64.bitWidth - 1 - nanoseconds.leadingZeroBitCount)
        buckets.increment(index)
        if let subBuckets, let fine = LatencySubBuckets.index(nanoseconds: nanoseconds) { subBuckets.increment(fine) }
    }

    /// Zeroes every bucket with atomic stores. Safe while other threads record: an increment that races with
    /// the store lands before it (and is cleared) or after it (and is kept); nothing tears.
    public func reset() {
        for index in 0..<Self.bucketCount { buckets.store(0, at: index) }
        guard let subBuckets else { return }
        for index in 0..<LatencySubBuckets.count { subBuckets.store(0, at: index) }
    }

    public func snapshot() -> HistogramSnapshot {
        HistogramSnapshot(
            buckets: buckets.snapshot(),
            subBuckets: subBuckets.map {
                SubBucketSnapshot(segments: LatencySubBuckets.segments, counts: $0.snapshot())
            }
        )
    }
}

/// Linear sub-buckets of the decide-to-posted histograms (T2, T3; 02-platform.md 8.1). Bucket i of a segment
/// counts values in (start + i * width, start + (i + 1) * width], upper end included, so "p99 <= gate" is decided
/// exactly whenever the gate is a bucket edge. Every 8.1 value up to 25 ms is one: the T2 target 0.5 and 2 ms and
/// gate 3 ms, the T3 target 2 and 8 ms and gate 15 ms, the T4 gate 10 ms, and the Intel values (1.5 times) 4.5
/// and 22.5 ms. Resolution: 10 us to 1 ms, 50 us to 5 ms, 250 us to 25 ms (260 buckets, 2 KiB per histogram).
public enum LatencySubBuckets {
    public struct Segment: Sendable, Hashable, Codable {
        /// Inclusive upper end; the segment starts just above the previous segment's end (0 for the first).
        public var upToNanoseconds: UInt64
        public var widthNanoseconds: UInt64

        public init(upToNanoseconds: UInt64, widthNanoseconds: UInt64) {
            self.upToNanoseconds = upToNanoseconds
            self.widthNanoseconds = widthNanoseconds
        }
    }

    public static let segments: [Segment] = [
        Segment(upToNanoseconds: 1_000_000, widthNanoseconds: 10_000),
        Segment(upToNanoseconds: 5_000_000, widthNanoseconds: 50_000),
        Segment(upToNanoseconds: 25_000_000, widthNanoseconds: 250_000),
    ]
    public static let count = 260
    public static let upperNanoseconds: UInt64 = 25_000_000

    /// The bucket of `nanoseconds` (0 counts in the first bucket), nil above `upperNanoseconds`. Constants only:
    /// no array access, no allocation, safe on the tap thread. `LatencySubBucketTests` pins it to `segments`.
    @inline(__always)
    static func index(nanoseconds: UInt64) -> Int? {
        if nanoseconds <= 1_000_000 { return nanoseconds == 0 ? 0 : Int((nanoseconds - 1) / 10_000) }
        if nanoseconds <= 5_000_000 { return 100 + Int((nanoseconds - 1_000_001) / 50_000) }
        if nanoseconds <= 25_000_000 { return 180 + Int((nanoseconds - 5_000_001) / 250_000) }
        return nil
    }
}

/// Counts of a histogram's linear sub-buckets with their layout, so a reader needs no knowledge of
/// `LatencySubBuckets` (and reads a future layout too).
public struct SubBucketSnapshot: Sendable, Hashable, Codable {
    /// A reader refuses layouts with more buckets than this (the JSON may come from another process).
    static let maximumBucketCount = 100_000

    public var segments: [LatencySubBuckets.Segment]
    public var counts: [UInt64]

    public init(segments: [LatencySubBuckets.Segment], counts: [UInt64]) {
        self.segments = segments
        self.counts = counts
    }

    /// Where the rank-th smallest sample lies: the bucket's bounds (lower excluded, upper included), the samples
    /// in earlier buckets and the samples in this one. Nil when the sub-buckets hold fewer than `rank` samples or
    /// the layout does not match the counts.
    public struct Position: Sendable, Hashable {
        public var lower: UInt64
        public var upper: UInt64
        public var before: UInt64
        public var count: UInt64
    }

    public func position(ofRank rank: UInt64) -> Position? {
        guard rank > 0, isConsistent else { return nil }
        var index = 0
        var start: UInt64 = 0
        var before: UInt64 = 0
        for segment in segments {
            var lower = start
            while lower < segment.upToNanoseconds {
                let count = counts[index]
                if count > 0 && before + count >= rank {
                    return Position(
                        lower: lower, upper: lower + segment.widthNanoseconds, before: before, count: count)
                }
                before += count
                lower += segment.widthNanoseconds
                index += 1
            }
            start = segment.upToNanoseconds
        }
        return nil
    }

    /// Inclusive upper end of the last segment; 0 without segments.
    public var upperNanoseconds: UInt64 { segments.last?.upToNanoseconds ?? 0 }

    /// Segments ascend, every width divides its segment, and the bucket count matches `counts`.
    public var isConsistent: Bool {
        var start: UInt64 = 0
        var total = 0
        for segment in segments {
            guard segment.widthNanoseconds > 0, segment.upToNanoseconds > start,
                (segment.upToNanoseconds - start) % segment.widthNanoseconds == 0
            else { return false }
            let buckets = (segment.upToNanoseconds - start) / segment.widthNanoseconds
            guard buckets <= UInt64(Self.maximumBucketCount - total) else { return false }
            total += Int(buckets)
            start = segment.upToNanoseconds
        }
        return !segments.isEmpty && total == counts.count
    }
}

public struct HistogramSnapshot: Sendable, Hashable, Codable {
    public var buckets: [UInt64]
    /// Linear sub-buckets (decide-to-posted histograms only). Nil for the other histograms and in JSON written
    /// before W3-A, which still decodes; a nil value is left out of the JSON.
    public var subBuckets: SubBucketSnapshot?

    public init(buckets: [UInt64], subBuckets: SubBucketSnapshot? = nil) {
        self.buckets = buckets
        self.subBuckets = subBuckets
    }

    public static let empty = HistogramSnapshot(buckets: Array(repeating: 0, count: Log2Histogram.bucketCount))
    public var count: UInt64 { buckets.reduce(0, +) }

    /// Upper bound (ns) of the log2 bucket containing the given fraction (0.5 = p50, 0.99 = p99). Nil when empty
    /// or when `fraction` is outside 0...1. Ignores the sub-buckets (the issue block keeps its log2 values);
    /// `precisePercentile` uses them.
    public func percentile(_ fraction: Double) -> UInt64? {
        guard let rank = rank(fraction) else { return nil }
        var seen: UInt64 = 0
        for (index, value) in buckets.enumerated() {
            seen += value
            if seen >= rank { return index >= 63 ? UInt64.max : (UInt64(1) << UInt64(index + 1)) - 1 }
        }
        return UInt64.max
    }

    /// Upper bound (ns) of the finest bucket containing the given fraction: the sub-bucket when the value lies in
    /// their range, so the answer is at most one sub-bucket width above the true value and never on the wrong side
    /// of an 8.1 gate; otherwise the log2 bucket (`percentile`).
    public func precisePercentile(_ fraction: Double) -> UInt64? {
        guard let rank = rank(fraction) else { return nil }
        if let position = subBuckets?.position(ofRank: rank) { return position.upper }
        return percentile(fraction)
    }

    /// Nearest rank of a fraction among the recorded samples (1-based); nil when empty or outside 0...1.
    public func rank(_ fraction: Double) -> UInt64? {
        let total = count
        guard total > 0, (0.0...1.0).contains(fraction) else { return nil }
        return max(1, UInt64((Double(total) * fraction).rounded(.up)))
    }
}

/// Monotonic counter safe on every thread.
public final class AtomicCounter: Sendable {
    private let storage = Atomic<UInt64>(0)
    public init() {}
    @inline(__always)
    public func increment(by amount: UInt64 = 1) { storage.wrappingAdd(amount, ordering: .relaxed) }
    public var value: UInt64 { storage.load(ordering: .relaxed) }
    /// Atomic store of zero; an increment racing with it is kept or cleared, never torn.
    public func reset() { storage.store(0, ordering: .relaxed) }
}

/// Platform budget metrics of 02-platform.md 8.1. Probe-tagged events (PLT-R810) go to `probe*` only, so user
/// metrics exclude them.
public final class PlatformMetrics: Sendable {
    public let callbackDuration = Log2Histogram()  // T1
    public let decideToPosted = Log2Histogram(subBuckets: true)  // T2
    public let decideToPostedWithAX = Log2Histogram(subBuckets: true)  // T3
    public let echoRoundTrip = Log2Histogram()
    public let heldWait = Log2Histogram()  // T5
    public let focusRefresh = Log2Histogram()  // T6
    public let probeDecideToPosted = Log2Histogram(subBuckets: true)  // T2 for latency-probe events only
    public let flushes = AtomicCounter()
    public let tapTimeouts = AtomicCounter()
    public let fallbackActivations = AtomicCounter()
    public let echoLosses = AtomicCounter()
    public let watchdogTrips = AtomicCounter()
    /// Events that could not be delivered after posting broke (ADR 0311): counted, never silent.
    public let lostWhilePostingBroken = AtomicCounter()
    /// AX call durations aggregated per bundle (PLT-R801); recorded on the ax and inject threads.
    public let axCallDurations = PerBundleHistograms()

    public init() {}

    /// Zeroes every histogram and counter (the integration hooks' `resetMetrics`, so a measured workload starts
    /// clean, ADR 0502). Atomic stores only, safe while the tap and the worker record: an event recorded during
    /// the reset is either cleared or kept, never half-counted. The per-bundle AX histograms are emptied too.
    public func reset() {
        for histogram in histograms { histogram.reset() }
        for counter in counters { counter.reset() }
        axCallDurations.reset()
    }

    private var histograms: [Log2Histogram] {
        [
            callbackDuration, decideToPosted, decideToPostedWithAX, echoRoundTrip, heldWait, focusRefresh,
            probeDecideToPosted,
        ]
    }

    private var counters: [AtomicCounter] {
        [flushes, tapTimeouts, fallbackActivations, echoLosses, watchdogTrips, lostWhilePostingBroken]
    }

    public func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            callbackDuration: callbackDuration.snapshot(), decideToPosted: decideToPosted.snapshot(),
            decideToPostedWithAX: decideToPostedWithAX.snapshot(), echoRoundTrip: echoRoundTrip.snapshot(),
            heldWait: heldWait.snapshot(), focusRefresh: focusRefresh.snapshot(), flushes: flushes.value,
            tapTimeouts: tapTimeouts.value, fallbackActivations: fallbackActivations.value,
            echoLosses: echoLosses.value, watchdogTrips: watchdogTrips.value,
            lostWhilePostingBroken: lostWhilePostingBroken.value)
    }
}

/// Bounded map of bundle -> histogram (at most `capacity` bundles, least recently used evicted). Uses a lock;
/// never touched by the tap thread.
public final class PerBundleHistograms: Sendable {
    private struct State: ~Copyable {
        var histograms: [BundleKey: Log2Histogram] = [:]
        var order: [BundleKey] = []  // least recently used first
    }

    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func record(_ bundle: BundleKey, nanoseconds: UInt64) {
        let histogram: Log2Histogram = state.withLock { state in
            if let existing = state.histograms[bundle] {
                state.order.removeAll { $0 == bundle }
                state.order.append(bundle)
                return existing
            }
            if state.order.count >= capacity {
                let evicted = state.order.removeFirst()
                state.histograms[evicted] = nil
            }
            let created = Log2Histogram()
            state.histograms[bundle] = created
            state.order.append(bundle)
            return created
        }
        histogram.record(nanoseconds: nanoseconds)
    }

    public func snapshot() -> [BundleKey: HistogramSnapshot] {
        state.withLock { $0.histograms.mapValues { $0.snapshot() } }
    }

    /// Forgets every bundle (`PlatformMetrics.reset()`).
    public func reset() {
        state.withLock { state in
            state.histograms = [:]
            state.order = []
        }
    }
}

public struct MetricsSnapshot: Sendable, Hashable, Codable {
    public var callbackDuration: HistogramSnapshot
    public var decideToPosted: HistogramSnapshot
    public var decideToPostedWithAX: HistogramSnapshot
    public var echoRoundTrip: HistogramSnapshot
    public var heldWait: HistogramSnapshot
    public var focusRefresh: HistogramSnapshot
    public var flushes: UInt64
    public var tapTimeouts: UInt64
    public var fallbackActivations: UInt64
    public var echoLosses: UInt64
    public var watchdogTrips: UInt64
    public var lostWhilePostingBroken: UInt64

    public init(
        callbackDuration: HistogramSnapshot, decideToPosted: HistogramSnapshot,
        decideToPostedWithAX: HistogramSnapshot, echoRoundTrip: HistogramSnapshot, heldWait: HistogramSnapshot,
        focusRefresh: HistogramSnapshot, flushes: UInt64, tapTimeouts: UInt64, fallbackActivations: UInt64,
        echoLosses: UInt64, watchdogTrips: UInt64, lostWhilePostingBroken: UInt64
    ) {
        self.callbackDuration = callbackDuration
        self.decideToPosted = decideToPosted
        self.decideToPostedWithAX = decideToPostedWithAX
        self.echoRoundTrip = echoRoundTrip
        self.heldWait = heldWait
        self.focusRefresh = focusRefresh
        self.flushes = flushes
        self.tapTimeouts = tapTimeouts
        self.fallbackActivations = fallbackActivations
        self.echoLosses = echoLosses
        self.watchdogTrips = watchdogTrips
        self.lostWhilePostingBroken = lostWhilePostingBroken
    }
}
