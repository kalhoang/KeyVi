// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-callback watchdog state (PLT-R306, ADR 0309). Implemented in the skeleton because both the pipeline
// (W1-F1, `enter`/`exit` on every callback) and the tap watchdog (W1-F2) use it (ADR 0313); W1-F2 owns it.

public import RealtimeSupport

/// `enter` writes the callback entry time, `exit` clears it; the utility-queue watchdog disables the tap if one
/// callback runs longer than 250 ms. The first callback after 2 s without callbacks signals `activitySignal`
/// so the watchdog arms its 250 ms check only while keys flow (PLT-R803, ADR 0309).
public final class CallbackWatchdog: Sendable {
    public static let callbackLimit: TimeSpan = .milliseconds(250)
    public static let idleAfter: TimeSpan = .seconds(2)
    private static let idleNanoseconds: UInt64 = 2_000_000_000

    private let enteredAt = Atomic<UInt64>(0)  // 0 = outside a callback
    private let lastEntry = Atomic<UInt64>(0)  // written by the tap only
    private let activitySignal: WakeSignal?

    public init(activitySignal: WakeSignal?) { self.activitySignal = activitySignal }

    /// Tap thread: first statement after `ReaderEpoch.enter()`.
    @inline(__always)
    public func enter(at now: MonotonicInstant) {
        let nanoseconds = max(now.nanoseconds, 1)
        let previous = lastEntry.load(ordering: .relaxed)
        lastEntry.store(nanoseconds, ordering: .relaxed)
        enteredAt.store(nanoseconds, ordering: .sequentiallyConsistent)
        if previous == 0 || nanoseconds &- previous > Self.idleNanoseconds { activitySignal?.signal() }
    }

    /// Tap thread: on every return path.
    @inline(__always)
    public func exit() { enteredAt.store(0, ordering: .sequentiallyConsistent) }

    /// Utility queue: nanoseconds the current callback has been running, nil when outside a callback.
    public func runningCallbackDuration(now: MonotonicInstant) -> UInt64? {
        let entered = enteredAt.load(ordering: .sequentiallyConsistent)
        return entered == 0 ? nil : now.nanoseconds(since: MonotonicInstant(nanoseconds: entered))
    }

    /// Utility queue: true while a callback is executing. After a trip, recovery waits until this is false.
    public var isInsideCallback: Bool { enteredAt.load(ordering: .sequentiallyConsistent) != 0 }

    /// Utility queue: entry time of the most recent callback (nil before the first one).
    public var lastCallbackEntry: MonotonicInstant? {
        let value = lastEntry.load(ordering: .relaxed)
        return value == 0 ? nil : MonotonicInstant(nanoseconds: value)
    }
}
