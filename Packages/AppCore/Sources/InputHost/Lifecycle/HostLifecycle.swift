// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lifecycle state machine of the input host (02-platform.md 2.1, PLT-R330-R333, PLT-R730, PLT-R731, ADR 0309)
// as a pure value type, so it is tested deterministically without threads, taps or services (ADR 0313).
// `InputHostController` (main actor, W2-A) feeds it inputs and performs the effects. Workstream W1-F2.

internal import AppModel
public import Injection
public import RealtimeSupport

public enum LifecycleInput: Sendable, Hashable {
    case launched
    /// A permission status from `PermissionMonitor`. The caller checks permissions immediately on wake, session
    /// activation and a system tap disable (PLT-R721) and feeds the result BEFORE `.sessionActive(true)` or
    /// `.tapDisabledBySystem`, so those inputs act on fresh permissions (PLT-R330 step 1, PLT-R333).
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

/// Phases: `starting` until permissions are known and the tap is created, `noPermission`, `running` (the tap
/// transforms, subject to per-key pauses), `sessionInactive` (PLT-R333), `failOpen(reason)` (PRD-R44: keys pass
/// unchanged). Effects come back in the order the caller performs them. Every transition into or out of
/// `failOpen` or `sessionInactive` (a pause) carries `.resetComposition` (PLT-R210); when the new phase is
/// `running` the reset comes before the publish, so the tap never transforms with a stale composition.
public struct HostLifecycle: Sendable, Hashable {
    /// PLT-R332: retry tap creation with backoff 1, 2, 5, 10 s (cap) while permissions look granted.
    public static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    /// PLT-R306: recovery attempt 2 s after a watchdog trip, only once the callback has returned (ADR 0309).
    public static let watchdogRecoveryDelay: Duration = .seconds(2)
    /// PLT-R330 step 5: the notice appears when more than `instabilityThreshold` system disables fall within
    /// this window, at most once per window.
    public static let instabilityWindow: Duration = .seconds(600)
    public static let instabilityThreshold = 3

    /// Who holds the one tap (PLT-R302): nobody, a creation in flight, or a live tap thread.
    private enum TapPresence: Sendable, Hashable { case none, creating, alive }

    public private(set) var phase: LifecycleSnapshot.Phase = .starting
    /// The user's "turn off" switch: a pause reason (`paused(userDisabled)`), not a lifecycle phase.
    public private(set) var userDisabled = false

    private var launched = false
    /// nil until the first status arrives.
    private var permissionsGranted: Bool?
    private var sessionActive = true
    private var tap = TapPresence.none
    private var retryAttempt = 0
    private var retryPending = false
    /// Nanosecond instants of the latest system disables, at most `instabilityThreshold + 1`.
    private var recentDisables: [UInt64] = []
    private var lastNoticeAt: UInt64?

    public init() {}

    /// Pure transition: returns the effects to perform, in order. Never blocks; the caller owns timers
    /// (`TimerScheduler`) and turns their firing into `.retryTimerFired`. `now` (the services' monotonic clock)
    /// dates system disables for the PLT-R330 instability window.
    public mutating func handle(_ input: LifecycleInput, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch input {
        case .launched: return launch()
        case .permissionsChanged(let status): return permissionsChanged(granted: Self.looksGranted(status))
        case .sessionActive(let active): return sessionChanged(active: active)
        case .userDisabled(let disabled): return userDisabledChanged(disabled)
        default: break
        }
        guard launched else { return [] }
        switch input {
        case .tapCreated: return tapCreated()
        case .tapCreationFailed: return tapCreationFailed()
        case .retryTimerFired: return retryFired()
        case .watchdogTripped(let trip): return watchdogTripped(trip, at: now)
        case .callbackExited: return callbackExited()
        case .postingBroken: return postingBroken()
        case .tapDisabledBySystem(let byTimeout):
            return systemDisabled(reason: byTimeout ? .tapTimeout : .tapDisabledByUserInput, at: now)
        case .launched, .permissionsChanged, .sessionActive, .userDisabled: return []
        }
    }

    /// "Permissions appear granted" (PLT-R332): health `ready`. `stale` and `noPermission` do not.
    static func looksGranted(_ status: PermissionStatus) -> Bool { status.health == .ready }

    // MARK: - Inputs

    private mutating func launch() -> [LifecycleEffect] {
        guard !launched else { return [] }
        launched = true
        switch permissionsGranted {
        case nil: return []
        case false?: return move(to: .noPermission)
        case true?: return beginCreation()
        }
    }

    private mutating func permissionsChanged(granted: Bool) -> [LifecycleEffect] {
        let previous = permissionsGranted
        permissionsGranted = granted
        guard launched else { return [] }
        var effects = granted ? permissionGranted(previous: previous) : permissionLost()
        if let previous, previous != granted { effects.append(.recordHealth(.permissionTransition)) }
        return effects
    }

    /// PLT-R731: permission back recreates the tap without a relaunch.
    private mutating func permissionGranted(previous: Bool?) -> [LifecycleEffect] {
        switch (tap, phase) {
        case (.none, .noPermission), (.none, .starting), (.none, .failOpen(.permissionRevoked)):
            return beginCreation()
        // Posting broke while permissions still looked granted: wait until they really return.
        case (.none, .failOpen(.postingBroken)) where previous == false:
            return beginCreation()
        case (.creating, .noPermission):
            // Lost and back while a creation is in flight: its result decides (PLT-R211, PLT-R332).
            return move(to: .starting)
        default:
            return []
        }
    }

    private mutating func permissionLost() -> [LifecycleEffect] {
        var effects = cancelPendingRetry()
        switch phase {
        case .running, .sessionInactive:
            effects += failOpenRemovingTap(.permissionRevoked)
        case .starting, .failOpen(.tapUnavailable):
            effects += move(to: .noPermission)
        case .failOpen(.postingBroken):
            effects += move(to: .failOpen(.permissionRevoked))
        case .noPermission, .failOpen(.permissionRevoked), .failOpen(.watchdog), .failOpen(.callbackStuck):
            // A tripped tap thread may still be inside its callback: it is removed once the callback returned.
            break
        }
        return effects
    }

    private mutating func tapCreated() -> [LifecycleEffect] {
        guard tap == .creating else { return [] }
        guard wantsTap else {
            tap = .none
            return [.removeTap]
        }
        tap = .alive
        retryAttempt = 0
        return move(to: sessionActive ? .running : .sessionInactive)
    }

    /// PLT-R332: failOpen(tapUnavailable), retry with backoff only while permissions look granted.
    private mutating func tapCreationFailed() -> [LifecycleEffect] {
        guard tap == .creating else { return [] }
        tap = .none
        guard wantsTap else { return [] }
        let delay = Self.backoff[min(retryAttempt, Self.backoff.count - 1)]
        retryAttempt += 1
        retryPending = true
        return move(to: .failOpen(.tapUnavailable)) + [.scheduleRetry(after: delay)]
    }

    private mutating func retryFired() -> [LifecycleEffect] {
        guard retryPending else { return [] }
        retryPending = false
        guard phase == .failOpen(.tapUnavailable), permissionsGranted == true, tap == .none else { return [] }
        // The phase stays failOpen(tapUnavailable) during the attempt, so the menu does not flicker.
        tap = .creating
        return [.createTap]
    }

    private mutating func watchdogTripped(_ trip: TapTrip, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch trip {
        case .callbackOverLimit:
            // PLT-R306: the watchdog already disabled the tap (keys flow); `.disableTap` repeats it from the
            // lifecycle owner. Nothing touches the tap thread, which may be stuck (ADR 0309).
            guard tapIsInstalled else { return [] }
            return publish(.failOpen(.watchdog)) + [
                .disableTap, .requestFlush(.failOpen), .resetComposition, .recordHealth(.watchdogTrip),
            ]
        case .callbackStuck:
            // ADR 0309: stay fail-open; never a second tap or tap thread (PLT-R302).
            guard phase == .failOpen(.watchdog) else { return [] }
            return move(to: .failOpen(.callbackStuck))
        case .unexpectedlyDisabled:
            // PLT-R331: the same procedure as a disabled event.
            return systemDisabled(reason: .tapReenabled, at: now)
        }
    }

    /// ADR 0309: the callback returned, so the same tap is re-enabled (or removed when permission went away).
    private mutating func callbackExited() -> [LifecycleEffect] {
        guard phase == .failOpen(.watchdog) || phase == .failOpen(.callbackStuck), tap == .alive else { return [] }
        guard permissionsGranted == true else { return failOpenRemovingTap(.permissionRevoked) }
        return [.reenableTap] + move(to: sessionActive ? .running : .sessionInactive) + [.recordHealth(.tapReenabled)]
    }

    /// PLT-R730: posting no longer works.
    private mutating func postingBroken() -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        return failOpenRemovingTap(.postingBroken) + [.recordHealth(.postingBroken)]
    }

    /// PLT-R330: re-enable (permissions are valid while a tap is installed: a revocation already removed it),
    /// reset, replay held events, record the reason, and the notice after more than 3 within 10 minutes.
    private mutating func systemDisabled(reason: HealthEventKindCode, at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        var effects: [LifecycleEffect] = [
            .reenableTap, .resetComposition, .requestFlush(.tapDisabled), .recordHealth(reason),
        ]
        if noteSystemDisable(at: now) { effects.append(.showTapInstabilityNotice) }
        return effects
    }

    /// PLT-R333: resign, sleep or lock pause the host; activation re-validates the tap (re-enable, idempotent)
    /// after the caller fed fresh permissions, then returns to running.
    private mutating func sessionChanged(active: Bool) -> [LifecycleEffect] {
        guard active != sessionActive else { return [] }
        sessionActive = active
        guard launched else { return [] }
        if !active {
            return phase == .running ? move(to: .sessionInactive) : []
        }
        guard phase == .sessionInactive, permissionsGranted == true, tap == .alive else { return [] }
        return [.reenableTap] + move(to: .running)
    }

    /// PLT-R210: entering or leaving `paused(userDisabled)` resets the composition.
    private mutating func userDisabledChanged(_ disabled: Bool) -> [LifecycleEffect] {
        guard disabled != userDisabled else { return [] }
        userDisabled = disabled
        return launched ? [.resetComposition] : []
    }

    // MARK: - Helpers

    /// A tap is installed and supposed to be enabled (not held by the watchdog).
    private var tapIsInstalled: Bool { tap == .alive && (phase == .running || phase == .sessionInactive) }

    /// A tap may be created now: permissions look granted and no tripped tap thread may still be stuck.
    private var wantsTap: Bool {
        guard launched, permissionsGranted == true else { return false }
        switch phase {
        case .failOpen(.watchdog), .failOpen(.callbackStuck): return false
        default: return true
        }
    }

    private mutating func beginCreation() -> [LifecycleEffect] {
        tap = .creating
        return move(to: .starting) + [.createTap]
    }

    private mutating func cancelPendingRetry() -> [LifecycleEffect] {
        retryAttempt = 0
        guard retryPending else { return [] }
        retryPending = false
        return [.cancelRetry]
    }

    /// PLT-R730: stop swallowing (the published phase), replay held events, reset, then remove the tap.
    private mutating func failOpenRemovingTap(_ reason: FailOpenReason) -> [LifecycleEffect] {
        tap = .none
        return publish(.failOpen(reason)) + [.requestFlush(.failOpen), .resetComposition, .removeTap]
    }

    /// Sets the phase and returns the publish effect, without the PLT-R210 reset (callers place it).
    private mutating func publish(_ new: LifecycleSnapshot.Phase) -> [LifecycleEffect] {
        guard new != phase else { return [] }
        phase = new
        return [.publish(new)]
    }

    /// Sets the phase with the PLT-R210 reset when a pause or fail-open is entered or left.
    private mutating func move(to new: LifecycleSnapshot.Phase) -> [LifecycleEffect] {
        let old = phase
        let published = publish(new)
        guard !published.isEmpty, Self.holdsComposition(old) || Self.holdsComposition(new) else { return published }
        return new == .running ? [.resetComposition] + published : published + [.resetComposition]
    }

    private static func holdsComposition(_ phase: LifecycleSnapshot.Phase) -> Bool {
        switch phase {
        case .failOpen, .sessionInactive: true
        case .noPermission, .starting, .running: false
        }
    }

    /// PLT-R330 step 5: true when this disable makes more than `instabilityThreshold` within the window and no
    /// notice was shown during the last window.
    private mutating func noteSystemDisable(at now: MonotonicInstant) -> Bool {
        let window = Self.instabilityWindow.nanoseconds
        recentDisables.append(now.nanoseconds)
        recentDisables.removeAll { now.nanoseconds(since: MonotonicInstant(nanoseconds: $0)) > window }
        if recentDisables.count > Self.instabilityThreshold + 1 { recentDisables.removeFirst() }
        guard recentDisables.count > Self.instabilityThreshold else { return false }
        if let lastNoticeAt, now.nanoseconds(since: MonotonicInstant(nanoseconds: lastNoticeAt)) < window {
            return false
        }
        lastNoticeAt = now.nanoseconds
        return true
    }
}
