// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lifecycle state machine of the input host (02-platform.md 2.1, PLT-R330-R333, PLT-R721, PLT-R730, PLT-R731, ADR 0309)
// as a pure value type, so it is tested deterministically without threads, taps or services (ADR 0313).
// `InputHostController` (main actor, W2-A) feeds it inputs and performs the effects. Workstream W1-F2.

internal import AppModel
public import Injection
public import RealtimeSupport

public enum LifecycleInput: Sendable, Hashable {
    case launched
    /// A permission status from `PermissionMonitor`. The caller checks permissions immediately on wake and session
    /// activation (PLT-R721) and feeds the result BEFORE `.sessionActive(true)`, so that input acts on fresh
    /// permissions (PLT-R333).
    case permissionsChanged(PermissionStatus)
    /// The answer to `.checkPermissionsLive`: a status checked after the request, off the main thread. Acts as
    /// `.permissionsChanged`, then re-enables a tap that a system disable left waiting (PLT-R330 step 1).
    case livePermissions(PermissionStatus)
    case tapCreated
    case tapCreationFailed
    /// A retry scheduled by `.scheduleRetry` fired.
    case retryTimerFired
    case watchdogTripped(TapTrip)
    /// After a `callbackOverLimit` trip: the watchdog observed that the callback returned.
    case callbackExited
    /// `EchoTracker` reported `.postingBroken` or the post preflight turned false (PLT-R323, PLT-R730).
    case postingBroken
    /// `tapDisabledByTimeout` or `tapDisabledByUserInput` reached the tap (PLT-R330). No permission check is needed
    /// first: the lifecycle asks for a live one before it re-enables.
    case tapDisabledBySystem(byTimeout: Bool)
    case sessionActive(Bool)
    case userDisabled(Bool)
    /// The guided test of "This app misbehaves" starts (`true`) or ends (`false`) typing with its own strategy
    /// (PLT-R1205 steps 3-5). Calls nest: only the first start and the matching last end change the state, and
    /// an end without a start is ignored.
    case diagnosticsPassThrough(Bool)
}

public enum LifecycleEffect: Sendable, Hashable {
    case publish(LifecycleSnapshot.Phase)
    case createTap
    /// PLT-R730 order: stop swallowing (already true via the published phase), flush held events, reset the
    /// composition, disable and remove the tap.
    case removeTap
    /// Watchdog trip: `CGEventTapEnable(false)` only; the tap thread may be stuck, so nothing else touches it.
    case disableTap
    /// PLT-R330 step 1, PLT-R306 recovery.
    case reenableTap
    /// Check permissions now, off the main thread and outside the tap callback (PLT-R304, PLT-R305), and feed the
    /// answer as `.livePermissions` (PLT-R330 step 1: a system disable re-enables only on a live answer).
    case checkPermissionsLive
    case requestFlush(FlushReason)
    case resetComposition
    case scheduleRetry(after: TimeSpan)
    case cancelRetry
    case recordHealth(HealthEventKindCode)
    /// More than 3 system disables within 10 minutes (PLT-R330 step 5).
    case showTapInstabilityNotice
    /// The phase is unchanged but a flag the tap reads changed (diagnostics pass-through): publish the snapshot
    /// again with the current phase.
    case publishFlags
}

/// Health kinds the lifecycle records (mirrors the Diagnostics `HealthEvent.Kind` cases it uses, so this
/// module's pure state machine does not construct dated events).
public enum HealthEventKindCode: String, Sendable, Hashable {
    case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, postingBroken, permissionTransition
    /// PLT-R330 step 6: the circuit breaker removed a tap the system kept disabling.
    case tapUnstable
}

/// Phases: `starting` until permissions are known and the tap is created, `noPermission`, `running` (the tap
/// transforms, subject to per-key pauses), `sessionInactive` (PLT-R333), `failOpen(reason)` (PRD-R44: keys pass
/// unchanged). Effects come back in the order the caller performs them. Every transition into or out of
/// `failOpen` or `sessionInactive` (a pause) carries `.resetComposition` (PLT-R210); when the new phase is
/// `running` the reset comes before the publish, so the tap never transforms with a stale composition.
public struct HostLifecycle: Sendable, Hashable {
    /// PLT-R332: retry tap creation with backoff 1, 2, 5, 10 s (cap) while permissions look granted.
    public static let backoff: [TimeSpan] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    /// PLT-R306: recovery attempt 2 s after a watchdog trip, only once the callback has returned (ADR 0309).
    public static let watchdogRecoveryDelay: TimeSpan = .seconds(2)
    /// PLT-R330 step 5: the notice appears when more than `instabilityThreshold` system disables fall within
    /// this window, at most once per window.
    public static let instabilityWindow: TimeSpan = .seconds(600)
    public static let instabilityThreshold = 3
    /// PLT-R330 step 5, PLT-R331: the OS disable event and the watchdog's `CGEventTapIsEnabled` check can both
    /// report one disable; reports closer than this count once toward the notice (both still run the procedure).
    public static let disableCoalescingWindow: TimeSpan = .seconds(1)
    /// PLT-R323, PLT-R730: echo loss and OS policy leave the permission status `ready`, so failOpen(postingBroken)
    /// retries the tap on this backoff while permissions look granted. A break soon after a recreation moves to
    /// the next step (cap 5 minutes), so a posting path that stays broken cannot cause a create/break loop.
    public static let postingBrokenBackoff: [TimeSpan] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(300),
    ]
    /// A recreated tap that posts for longer than the previous delay plus this interval resets the backoff.
    public static let postingBrokenStableInterval: TimeSpan = .seconds(600)
    /// PLT-R330 step 6 (circuit breaker): `breakerThreshold` distinct system disables (reports within
    /// `disableCoalescingWindow` count once) within `breakerWindow` remove the tap instead of re-enabling it. A
    /// healthy tap is disabled rarely, and its callback is far below the timeout; two disables within 30 s mean that
    /// re-enabling does not help, as in the incident of 15/11/2026 (one disable about every 10.5 s, input stalled in
    /// between): the second disable came 10 s after the first, where three would have meant 21 s of stalled input.
    /// A false trip costs a short fail-open period with a status line, never a blocked keyboard.
    public static let breakerWindow: TimeSpan = .seconds(30)
    public static let breakerThreshold = 2
    /// PLT-R332 (amended): the removed tap comes back only after this delay, after a live permission check, and is
    /// on probation for `breakerProbation`: one system disable then removes it again with the next delay (cap 5
    /// minutes), so a cause that persists stalls input for at most one disable per attempt, ever less often.
    public static let breakerBackoff: [TimeSpan] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300)]
    public static let breakerProbation: TimeSpan = .seconds(60)
    /// A trip later than the previous delay plus this interval starts the backoff again.
    public static let breakerStableInterval: TimeSpan = .seconds(600)
    /// PLT-R330 step 1 (amended): how long a system disable waits for its live permission answer. A report of the
    /// still disabled tap after this (the watchdog's 5 s check, PLT-R331) means the answer is not coming (a TCC call
    /// that stalls): the tap is removed as for a failed creation, so the host never sits in `running` with a disabled
    /// tap, and reports before it are the same disable, never a second one for the breaker.
    public static let liveCheckOverdue: TimeSpan = .seconds(3)

    /// Who holds the one tap (PLT-R302): nobody, a creation in flight, or a live tap thread.
    private enum TapPresence: Sendable, Hashable { case none, creating, alive }

    public private(set) var phase: LifecycleSnapshot.Phase = .starting
    /// The user's "turn off" switch: a pause reason (`paused(userDisabled)`), not a lifecycle phase.
    public private(set) var userDisabled = false
    /// The guided test is typing: a pause reason (`paused(diagnosticsTest)`), not a lifecycle phase.
    public var diagnosticsPassThrough: Bool { passThroughDepth > 0 }

    /// Nesting depth of `.diagnosticsPassThrough` calls.
    private var passThroughDepth = 0

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
    /// The latest disable that counted (not coalesced into the one before), for the coalescing window.
    private var lastCountedDisable: UInt64?
    /// Counted disables within `breakerWindow`, for the circuit breaker.
    private var breakerDisables: [UInt64] = []
    /// Index into `breakerBackoff` used by the latest trip, and when it happened.
    private var breakerAttempt = 0
    private var lastBreakerTripAt: UInt64?
    /// A tap is being recreated after a trip; once created it is on probation until `probationUntil`.
    private var breakerRecovering = false
    private var probationUntil: UInt64?
    /// A system disable waits for `.livePermissions` before the tap is re-enabled (PLT-R330 step 1): the instant it
    /// asked, nil when nothing waits. Cleared by every path that enables or removes the tap.
    private var reenableRequestedAt: UInt64?
    /// Index into `postingBrokenBackoff` used by the latest postingBroken, and when it happened.
    private var postingBrokenAttempt = 0
    private var lastPostingBrokenAt: UInt64?

    public init() {}

    /// Pure transition: returns the effects to perform, in order. Never blocks; the caller owns timers
    /// (`TimerScheduler`) and turns their firing into `.retryTimerFired`. `now` (the services' monotonic clock)
    /// dates system disables for the PLT-R330 instability window.
    public mutating func handle(_ input: LifecycleInput, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch input {
        case .launched: return launch()
        case .permissionsChanged(let status): return permissionsChanged(granted: Self.looksGranted(status))
        case .livePermissions(let status): return livePermissions(granted: Self.looksGranted(status))
        case .sessionActive(let active): return sessionChanged(active: active)
        case .userDisabled(let disabled): return userDisabledChanged(disabled)
        case .diagnosticsPassThrough(let on): return passThroughChanged(on)
        default: break
        }
        guard launched else { return [] }
        switch input {
        case .tapCreated: return tapCreated(at: now)
        case .tapCreationFailed: return tapCreationFailed()
        case .retryTimerFired: return retryFired()
        case .watchdogTripped(let trip): return watchdogTripped(trip, at: now)
        case .callbackExited: return callbackExited()
        case .postingBroken: return postingBroken(at: now)
        case .tapDisabledBySystem(let byTimeout):
            return systemDisabled(reason: byTimeout ? .tapTimeout : .tapDisabledByUserInput, at: now)
        case .launched, .permissionsChanged, .livePermissions, .sessionActive, .userDisabled, .diagnosticsPassThrough:
            return []
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
        var effects = granted ? permissionGranted() : permissionLost()
        if let previous, previous != granted { effects.append(.recordHealth(.permissionTransition)) }
        return effects
    }

    /// PLT-R731: permission back recreates the tap without a relaunch. A failOpen(postingBroken) host keeps its
    /// own retry timer: a real revocation already moved it to failOpen(permissionRevoked).
    private mutating func permissionGranted() -> [LifecycleEffect] {
        switch (tap, phase) {
        case (.none, .noPermission), (.none, .starting), (.none, .failOpen(.permissionRevoked)):
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

    /// PLT-R330 step 1: the live answer a system disable waited for. Not granted: `permissionsChanged` already
    /// removed the tap (PLT-R730). Granted: the same tap is enabled again, once for all reports of that disable.
    private mutating func livePermissions(granted: Bool) -> [LifecycleEffect] {
        var effects = permissionsChanged(granted: granted)
        let pending = reenableRequestedAt != nil
        reenableRequestedAt = nil
        guard pending, granted, tapIsInstalled else { return effects }
        effects.append(.reenableTap)
        return effects
    }

    private mutating func tapCreated(at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tap == .creating else { return [] }
        guard wantsTap else {
            tap = .none
            return [.removeTap]
        }
        tap = .alive
        retryAttempt = 0
        reenableRequestedAt = nil
        breakerDisables.removeAll()  // a fresh tap: disables of the previous one never pair with its first
        if breakerRecovering {
            breakerRecovering = false
            probationUntil = now.nanoseconds &+ Self.breakerProbation.unsignedNanoseconds
        }
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
        let retryPhase = phase == .failOpen(.tapUnavailable) || phase == .failOpen(.postingBroken)
        guard retryPhase, permissionsGranted == true, tap == .none else { return [] }
        // The phase stays fail-open during the attempt, so the menu does not flicker.
        tap = .creating
        return [.createTap]
    }

    private mutating func watchdogTripped(_ trip: TapTrip, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch trip {
        case .callbackOverLimit:
            // PLT-R306: the watchdog already disabled the tap (keys flow); `.disableTap` repeats it from the
            // lifecycle owner. Nothing touches the tap thread, which may be stuck (ADR 0309).
            guard tapIsInstalled else { return [] }
            reenableRequestedAt = nil  // the watchdog holds the tap now; `callbackExited` decides
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

    /// PLT-R730: posting no longer works. PLT-R323: echo loss or OS policy can leave permissions `ready`, and the
    /// monitor then never reports a change, so the tap is retried on the bounded `postingBrokenBackoff`.
    private mutating func postingBroken(at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        let delay = notePostingBroken(at: now)
        retryPending = true
        return failOpenRemovingTap(.postingBroken) + [.recordHealth(.postingBroken), .scheduleRetry(after: delay)]
    }

    /// PLT-R330 (amended 15/11/2026): reset, replay held events, record the reason, the notice after more than 3
    /// within 10 minutes, then a live permission check; the tap is re-enabled only when that check answers granted
    /// (`.livePermissions`), never on the cached status, because a revoked grant leaves an untrusted tap that
    /// stalls input until it is removed (the incident of 15/11/2026). A tap the system keeps disabling is removed
    /// by the circuit breaker instead (`breakerWindow`). Every report of an enabled tap runs the procedure (a second
    /// disable within the coalescing window is possible and needs the reset), but reports within
    /// `disableCoalescingWindow` of the last counted one count once (PLT-R331); a report while the live answer is
    /// pending is the same disable (`stillWaiting`).
    private mutating func systemDisabled(reason: HealthEventKindCode, at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        let procedure: [LifecycleEffect] = [.resetComposition, .requestFlush(.tapDisabled), .recordHealth(reason)]
        if let requestedAt = reenableRequestedAt { return stillWaiting(since: requestedAt, at: now, procedure) }
        var effects = procedure
        let counted = countDisable(at: now)
        if counted.notice { effects.append(.showTapInstabilityNotice) }
        if counted.trip { return effects + tripBreaker(at: now) }
        reenableRequestedAt = now.nanoseconds
        return effects + [.checkPermissionsLive]
    }

    /// A report while the live answer is pending: the tap has stayed disabled since, so it is the same disable. It
    /// runs the procedure (idempotent) but counts for neither the notice nor the breaker and asks for no second
    /// check. Once the answer is `liveCheckOverdue` late it is not coming (a TCC call that stalls): the tap is removed
    /// and retried like a failed creation (PLT-R332), whose retry checks permissions first, so the host shows
    /// `failOpen(tapUnavailable)` instead of a silently disabled tap.
    private mutating func stillWaiting(
        since requestedAt: UInt64, at now: MonotonicInstant, _ procedure: [LifecycleEffect]
    ) -> [LifecycleEffect] {
        let waited = now.nanoseconds(since: MonotonicInstant(nanoseconds: requestedAt))
        guard waited >= Self.liveCheckOverdue.unsignedNanoseconds else { return procedure }
        let delay = Self.backoff[min(retryAttempt, Self.backoff.count - 1)]
        retryAttempt += 1
        retryPending = true
        return failOpenRemovingTap(.tapUnavailable) + [.recordHealth(.tapUnstable), .scheduleRetry(after: delay)]
    }

    /// PLT-R330 step 6: remove the tap (fail open, keys flow), retry on `breakerBackoff` while permissions look
    /// granted (the retry fire checks them live first), and check now, so a revocation shows as such at once.
    private mutating func tripBreaker(at now: MonotonicInstant) -> [LifecycleEffect] {
        let delay = noteBreakerTrip(at: now)
        breakerDisables.removeAll()
        probationUntil = nil
        breakerRecovering = true
        retryAttempt = 0
        retryPending = true
        return failOpenRemovingTap(.tapUnavailable) + [
            .recordHealth(.tapUnstable), .scheduleRetry(after: delay), .checkPermissionsLive,
        ]
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
        reenableRequestedAt = nil  // the activation re-enables on the fresh status the caller fed (PLT-R333)
        return [.reenableTap] + move(to: .running)
    }

    /// PLT-R210: entering or leaving `paused(userDisabled)` resets the composition.
    private mutating func userDisabledChanged(_ disabled: Bool) -> [LifecycleEffect] {
        guard disabled != userDisabled else { return [] }
        userDisabled = disabled
        return launched ? [.resetComposition] : []
    }

    /// PLT-R1205, PLT-R210: entering stops transforming in the tap's next callback (publish), then resets;
    /// leaving resets first, so the tap never transforms with a stale composition, then publishes.
    private mutating func passThroughChanged(_ on: Bool) -> [LifecycleEffect] {
        let wasOn = diagnosticsPassThrough
        if on {
            passThroughDepth += 1
        } else {
            guard passThroughDepth > 0 else { return [] }
            passThroughDepth -= 1
        }
        guard diagnosticsPassThrough != wasOn, launched else { return [] }
        return on ? [.publishFlags, .resetComposition] : [.resetComposition, .publishFlags]
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
        breakerRecovering = false
        guard retryPending else { return [] }
        retryPending = false
        return [.cancelRetry]
    }

    /// PLT-R730: stop swallowing (the published phase), replay held events, reset, then remove the tap.
    private mutating func failOpenRemovingTap(_ reason: FailOpenReason) -> [LifecycleEffect] {
        tap = .none
        reenableRequestedAt = nil
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

    /// One system disable toward the notice (step 5) and the circuit breaker (step 6). A report within
    /// `disableCoalescingWindow` of the last counted one is the same disable and counts for neither.
    private mutating func countDisable(at now: MonotonicInstant) -> (notice: Bool, trip: Bool) {
        if let last = lastCountedDisable,
            now.nanoseconds(since: MonotonicInstant(nanoseconds: last))
                < Self.disableCoalescingWindow.unsignedNanoseconds
        {
            return (false, false)
        }
        lastCountedDisable = now.nanoseconds
        let notice = noteSystemDisable(at: now)
        let window = Self.breakerWindow.unsignedNanoseconds
        breakerDisables.append(now.nanoseconds)
        breakerDisables.removeAll { now.nanoseconds(since: MonotonicInstant(nanoseconds: $0)) > window }
        let onProbation = probationUntil.map { now.nanoseconds < $0 } ?? false
        return (notice, onProbation || breakerDisables.count >= Self.breakerThreshold)
    }

    /// PLT-R332 (amended): the delay before the tap comes back after this trip. A trip within the previous delay
    /// plus `breakerStableInterval` of the previous trip moves one step up the backoff; otherwise it restarts.
    private mutating func noteBreakerTrip(at now: MonotonicInstant) -> TimeSpan {
        let backoff = Self.breakerBackoff
        if let last = lastBreakerTripAt {
            let horizon = backoff[breakerAttempt].unsignedNanoseconds + Self.breakerStableInterval.unsignedNanoseconds
            let soon = now.nanoseconds(since: MonotonicInstant(nanoseconds: last)) < horizon
            breakerAttempt = soon ? min(breakerAttempt + 1, backoff.count - 1) : 0
        }
        lastBreakerTripAt = now.nanoseconds
        return backoff[breakerAttempt]
    }

    /// PLT-R330 step 5: true when this disable makes more than `instabilityThreshold` within the window and no
    /// notice was shown during the last window. Called once per counted (not coalesced) disable.
    private mutating func noteSystemDisable(at now: MonotonicInstant) -> Bool {
        let window = Self.instabilityWindow.unsignedNanoseconds
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

    /// PLT-R323: the retry delay for this postingBroken. A break within the previous delay plus
    /// `postingBrokenStableInterval` of the previous break moves one step up the backoff; otherwise it restarts.
    private mutating func notePostingBroken(at now: MonotonicInstant) -> TimeSpan {
        let backoff = Self.postingBrokenBackoff
        if let last = lastPostingBrokenAt {
            let horizon =
                backoff[postingBrokenAttempt].unsignedNanoseconds + Self.postingBrokenStableInterval.unsignedNanoseconds
            let soon = now.nanoseconds(since: MonotonicInstant(nanoseconds: last)) < horizon
            postingBrokenAttempt = soon ? min(postingBrokenAttempt + 1, backoff.count - 1) : 0
        }
        lastPostingBrokenAt = now.nanoseconds
        return backoff[postingBrokenAttempt]
    }
}
