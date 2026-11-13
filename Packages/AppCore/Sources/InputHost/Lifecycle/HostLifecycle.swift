// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lifecycle state machine of the input host (02-platform.md 2.1, PLT-R330-R332, PLT-R730, PLT-R731, ADR 0309)
// as a pure value type, so it is tested deterministically without threads, taps or services (ADR 0313).
// `InputHostController` (main actor, W2-A) feeds it inputs and performs the effects. Workstream W1-F2.

internal import AppModel
public import Injection

public enum LifecycleInput: Sendable, Hashable {
    case launched
    case permissionsChanged(PermissionStatus)
    case tapCreated
    case tapCreationFailed
    /// A retry scheduled by `.scheduleRetry` fired.
    case retryTimerFired
    case watchdogTripped(TapTrip)
    /// After a `callbackOverLimit` trip: the watchdog observed that the callback returned.
    case callbackExited
    /// `EchoTracker` reported `.postingBroken` or the post preflight turned false (PLT-R323, PLT-R730).
    case postingBroken
    case tapDisabledBySystem(byTimeout: Bool)
    case sessionActive(Bool)
    case userDisabled(Bool)
}

public enum LifecycleEffect: Sendable, Hashable {
    case publish(LifecycleSnapshot.Phase)
    case createTap
    /// PLT-R730 order: stop swallowing (already true via the published phase), flush held events, reset the
    /// composition, disable and remove the tap.
    case removeTap
    /// Watchdog trip: `CGEventTapEnable(false)` only; the tap thread may be stuck, so nothing else touches it.
    case disableTap
    /// PLT-R330 step 1.
    case reenableTap
    case requestFlush(FlushReason)
    case resetComposition
    case scheduleRetry(after: Duration)
    case cancelRetry
    case recordHealth(HealthEventKindCode)
    /// More than 3 system disables within 10 minutes (PLT-R330 step 5).
    case showTapInstabilityNotice
}

/// Health kinds the lifecycle records (mirrors the Diagnostics `HealthEvent.Kind` cases it uses, so this
/// module's pure state machine does not construct dated events).
public enum HealthEventKindCode: String, Sendable, Hashable {
    case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, postingBroken, permissionTransition
}

public struct HostLifecycle: Sendable, Hashable {
    /// PLT-R332: retry tap creation with backoff 1, 2, 5, 10 s (cap) while permissions look granted.
    public static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    /// PLT-R306: recovery attempt 2 s after a watchdog trip, only once the callback has returned (ADR 0309).
    public static let watchdogRecoveryDelay: Duration = .seconds(2)

    public init() { unimplemented() }

    public var phase: LifecycleSnapshot.Phase { unimplemented() }

    /// Pure transition: returns the effects to perform, in order. Never blocks; the caller owns timers
    /// (`TimerScheduler`) and turns their firing into `.retryTimerFired`.
    public mutating func handle(_ input: LifecycleInput) -> [LifecycleEffect] { unimplemented() }
}
