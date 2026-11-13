// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Always-on, content-free, lock-free histograms (PLT-R801): fixed memory, log2 buckets, safe on the tap.
// Implemented in the skeleton because the pipeline and the worker record into them on every event
// (docs/decisions/0313-testability-seams.md); workstream W1-A owns, benchmarks and may optimise them.

public import AppModel
internal import RealtimeSupport
internal import Synchronization

/// 64 log2 buckets of nanoseconds (bucket i counts values in [2^i, 2^(i+1)); bucket 0 also counts 0), one
/// `Atomic<UInt64>` each.
public final class Log2Histogram: Sendable {
    public static let bucketCount = 64
    private let buckets = AtomicUInt64Array(count: Log2Histogram.bucketCount)

    public init() {}

    /// Lock-free, allocation-free; allowed on the tap thread (PLT-R304).
    @inline(__always)
    public func record(nanoseconds: UInt64) {
        let index = nanoseconds == 0 ? 0 : (UInt64.bitWidth - 1 - nanoseconds.leadingZeroBitCount)
        buckets.increment(index)
    }

    public func snapshot() -> HistogramSnapshot { HistogramSnapshot(buckets: buckets.snapshot()) }
}

public struct HistogramSnapshot: Sendable, Hashable, Codable {
    public var buckets: [UInt64]
    public init(buckets: [UInt64]) { self.buckets = buckets }
    public static let empty = HistogramSnapshot(buckets: Array(repeating: 0, count: Log2Histogram.bucketCount))
    public var count: UInt64 { buckets.reduce(0, +) }

    /// Upper bound (ns) of the bucket containing the given fraction (0.5 = p50, 0.99 = p99). Nil when empty or
    /// when `fraction` is outside 0...1.
    public func percentile(_ fraction: Double) -> UInt64? {
        let total = count
        guard total > 0, (0.0...1.0).contains(fraction) else { return nil }
        let rank = max(1, UInt64((Double(total) * fraction).rounded(.up)))
        var seen: UInt64 = 0
        for (index, value) in buckets.enumerated() {
            seen += value
            if seen >= rank { return index >= 63 ? UInt64.max : (UInt64(1) << UInt64(index + 1)) - 1 }
        }
        return UInt64.max
    }
}

/// Monotonic counter safe on every thread.
public final class AtomicCounter: Sendable {
    private let storage = Atomic<UInt64>(0)
    public init() {}
    @inline(__always)
    public func increment(by amount: UInt64 = 1) { storage.wrappingAdd(amount, ordering: .relaxed) }
    public var value: UInt64 { storage.load(ordering: .relaxed) }
}

/// Platform budget metrics of 02-platform.md 8.1. Probe-tagged events (PLT-R810) go to `probe*` only, so user
/// metrics exclude them.
public final class PlatformMetrics: Sendable {
    public let callbackDuration = Log2Histogram()  // T1
    public let decideToPosted = Log2Histogram()  // T2
    public let decideToPostedWithAX = Log2Histogram()  // T3
    public let echoRoundTrip = Log2Histogram()
    public let heldWait = Log2Histogram()  // T5
    public let focusRefresh = Log2Histogram()  // T6
    public let probeDecideToPosted = Log2Histogram()  // T2 for latency-probe events only
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
