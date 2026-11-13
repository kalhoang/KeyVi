// SPDX-License-Identifier: GPL-3.0-or-later

internal import Darwin

/// Point on the uptime clock (`CLOCK_UPTIME_RAW`, the mach absolute time base) in nanoseconds.
public struct MonotonicInstant: Sendable, Hashable, Comparable, BitwiseCopyable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static let zero = MonotonicInstant(nanoseconds: 0)

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func advanced(byMicroseconds microseconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: nanoseconds &+ microseconds &* 1_000)
    }

    /// Saturating difference in nanoseconds.
    public func nanoseconds(since earlier: MonotonicInstant) -> UInt64 {
        nanoseconds >= earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
    }

    /// Saturating difference as a span (zero when `earlier` is later).
    public func duration(since earlier: MonotonicInstant) -> TimeSpan {
        .nanoseconds(nanoseconds(since: earlier))
    }
}

/// Monotonic clock for timestamps, deadlines and pacing. `sleep(until:)` is allowed only on the `inject`
/// thread (PLT-R409) and in tests; never on the tap thread (PLT-R305).
public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
    func sleep(until deadline: MonotonicInstant)
}

/// Production clock. `now()` is a vDSO-style read with no syscall on Apple silicon.
public struct MachClock: MonotonicClock {
    private let numerator: UInt64
    private let denominator: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = UInt64(info.denom)
    }

    @inline(__always)
    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    public func sleep(until deadline: MonotonicInstant) {
        // The kernel reads a deadline of 0 as "no deadline" and would block forever, so a deadline that has
        // already passed returns at once instead of reaching mach_wait_until.
        guard deadline > now() else { return }
        // Absolute deadline in mach ticks (PLT-R409).
        let ticks = deadline.nanoseconds.multipliedFullWidth(by: denominator)
        let (quotient, _) = numerator.dividingFullWidth(ticks)
        mach_wait_until(max(quotient, 1))
    }
}
