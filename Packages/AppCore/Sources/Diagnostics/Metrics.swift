// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Always-on, content-free, lock-free histograms (PLT-R801): fixed memory, log2 buckets, safe on the tap.

public import AppModel

/// 64 log2 buckets of nanoseconds (bucket i counts values in [2^i, 2^(i+1))), one `Atomic<UInt64>` each.
public final class Log2Histogram: Sendable {
    public init() { unimplemented() }
    /// Lock-free, allocation-free; allowed on the tap thread (PLT-R304).
    public func record(nanoseconds: UInt64) { unimplemented() }
    public func snapshot() -> HistogramSnapshot { unimplemented() }
}

public struct HistogramSnapshot: Sendable, Hashable, Codable {
    public var buckets: [UInt64]
    public init(buckets: [UInt64]) { self.buckets = buckets }
    public var count: UInt64 { buckets.reduce(0, +) }
    /// Upper bound (ns) of the bucket containing the given fraction (0.5 = p50, 0.99 = p99).
    public func percentile(_ fraction: Double) -> UInt64? { unimplemented() }
}

/// Monotonic counter safe on every thread.
public final class AtomicCounter: Sendable {
    public init() { unimplemented() }
    public func increment(by amount: UInt64 = 1) { unimplemented() }
    public var value: UInt64 { unimplemented() }
}

/// Platform budget metrics of 02-platform.md 8.1. Probe-tagged events (PLT-R810) go to `probe*` only, so user
/// metrics exclude them.
public final class PlatformMetrics: Sendable {
    public let callbackDuration: Log2Histogram  // T1
    public let decideToPosted: Log2Histogram  // T2
    public let decideToPostedWithAX: Log2Histogram  // T3
    public let echoRoundTrip: Log2Histogram
    public let heldWait: Log2Histogram  // T5
    public let focusRefresh: Log2Histogram  // T6
    public let probeDecideToPosted: Log2Histogram  // T2 for latency-probe events only
    public let flushes: AtomicCounter
    public let tapTimeouts: AtomicCounter
    public let fallbackActivations: AtomicCounter
    public let echoLosses: AtomicCounter
    public let watchdogTrips: AtomicCounter
    /// AX call durations aggregated per bundle (PLT-R801); recorded on the ax and inject threads.
    public let axCallDurations: PerBundleHistograms

    public init() { unimplemented() }
    public func snapshot() -> MetricsSnapshot { unimplemented() }
}

/// Bounded map of bundle -> histogram (at most 64 bundles, least recently used evicted). Uses a lock;
/// never touched by the tap thread.
public final class PerBundleHistograms: Sendable {
    public init(capacity: Int = 64) { unimplemented() }
    public func record(_ bundle: BundleKey, nanoseconds: UInt64) { unimplemented() }
    public func snapshot() -> [BundleKey: HistogramSnapshot] { unimplemented() }
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
}
