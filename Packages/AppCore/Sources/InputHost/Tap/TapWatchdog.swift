// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R306, PLT-R331 and snapshot reclamation on the utility queue (ADR 0309, ADR 0303). Workstream W1-F2.

internal import AppModel
public import RealtimeSupport

/// Why the watchdog acted.
public enum TapTrip: Sendable, Hashable {
    /// One callback ran longer than 250 ms: the tap was disabled (`CGEventTapEnable(false)`, keys flow) and
    /// the host enters `failOpen(watchdog)`. Recovery is attempted 2 s later only if the callback has returned.
    case callbackOverLimit(microseconds: UInt64)
    /// 2 s after a trip the callback still has not returned: stay in `failOpen(callbackStuck)`; never create a
    /// second tap or a second tap thread that would share the reader epoch (ADR 0309).
    case callbackStuck(microseconds: UInt64)
    /// `CGEventTapIsEnabled` false without a disabled event: run the PLT-R330 procedure.
    case unexpectedlyDisabled
}

/// Watchdog for the tap. The 250 ms callback check runs only while keys flow (armed by `callbackActivity()`,
/// which the tap's activity `WakeSignal` calls, disarmed after 2 s without callbacks), so idle wakeups stay at
/// zero (PLT-R803). Every 5 s (with leeway) it checks `isEnabled` (PLT-R331) and calls
/// `TapSnapshots.reclaimAll()` so retired snapshot boxes are freed even when no writer publishes (ADR 0303).
public final class TapWatchdog: Sendable {
    public static let enabledCheckInterval: Duration = .seconds(5)
    public static let recoveryDelay: Duration = .seconds(2)

    public init(
        tap: any TapControl, callbacks: CallbackWatchdog, snapshots: TapSnapshots, scheduler: any TimerScheduler,
        clock: any MonotonicClock, onTrip: @escaping @Sendable (TapTrip) -> Void
    ) { unimplemented() }

    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    /// The tap's activity signal fired (first callback after 2 s idle): arm the 250 ms check.
    public func callbackActivity() { unimplemented() }
    /// Called on wake, session activation, permission change (PLT-R331).
    public func checkNow() { unimplemented() }
}
