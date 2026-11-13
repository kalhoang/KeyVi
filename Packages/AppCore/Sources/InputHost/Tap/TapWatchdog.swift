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

/// Frees retired snapshot boxes (ADR 0303). `TapSnapshots` conforms; tests count calls.
public protocol SnapshotReclaiming: Sendable {
    func reclaimAll()
}

extension TapSnapshots: SnapshotReclaiming {}

/// Watchdog for the tap. The 250 ms callback check runs only while keys flow (armed by `callbackActivity()`,
/// which the tap's activity `WakeSignal` calls, disarmed after 2 s without callbacks), so idle wakeups stay at
/// zero (PLT-R803). A check that finds a callback still under the limit adds one one-shot check at the moment
/// it would cross 250 ms, so detection takes about 275 ms at worst (ADR 0309). Every 5 s (with leeway) it checks
/// `isEnabled` (PLT-R331) and calls `reclaimAll()` so retired snapshot boxes are freed even when no writer
/// publishes (ADR 0303).
///
/// After a trip the watchdog disables the tap itself (keys flow at once) and reports `onTrip`; 2 s later it
/// reports `onCallbackReturned` if the callback has returned, otherwise `onTrip(.callbackStuck)`. A stuck
/// callback is re-checked on every 5 s tick and reported as returned if it ever comes back; the watchdog never
/// touches the tap again by itself. Handlers run on the scheduler's queue (utility in production), outside
/// the watchdog's lock, so they may call back into it.
public final class TapWatchdog: Sendable {
    public static let enabledCheckInterval: TimeSpan = .seconds(5)
    public static let recoveryDelay: TimeSpan = .seconds(2)
    /// Period of the callback check while keys flow (ADR 0309).
    public static let callbackCheckInterval: TimeSpan = CallbackWatchdog.callbackLimit

    private static let enabledCheckLeeway: TimeSpan = .seconds(1)
    private static let limitNanoseconds = CallbackWatchdog.callbackLimit.unsignedNanoseconds
    private static let idleNanoseconds = CallbackWatchdog.idleAfter.unsignedNanoseconds
    /// The crossing check lands just past the limit, so "more than 250 ms" is already true when it runs.
    private static let crossingMargin: UInt64 = 1_000_000

    private enum Mode: Sendable, Hashable {
        /// Normal operation: the enabled check reports a disabled tap.
        case watching
        /// The watchdog disabled the tap; the recovery check is pending.
        case tripped
        /// The callback did not return within the recovery delay.
        case stuck
        /// The callback returned; waiting until the lifecycle owner re-enabled the tap.
        case awaitingReenable
    }

    private enum Action {
        case disableTap
        case report(TapTrip)
        case callbackReturned
    }

    /// One read of the callback watchdog and the tap, taken outside the lock.
    private struct Observation {
        var now: MonotonicInstant
        var running: UInt64?
        var lastEntry: MonotonicInstant?
        var tapRunning: Bool
        var tapEnabled: Bool
    }

    private struct State: Sendable {
        var started = false
        var mode = Mode.watching
        var armedAt: MonotonicInstant?
        var enabledTimer: (any ScheduledTimer)?
        var checkTimer: (any ScheduledTimer)?
        var crossingTimer: (any ScheduledTimer)?
        var recoveryTimer: (any ScheduledTimer)?

        mutating func disarm() {
            checkTimer?.cancel()
            crossingTimer?.cancel()
            checkTimer = nil
            crossingTimer = nil
            armedAt = nil
        }

        mutating func cancelAll() {
            disarm()
            enabledTimer?.cancel()
            recoveryTimer?.cancel()
            enabledTimer = nil
            recoveryTimer = nil
        }
    }

    private let tap: any TapControl
    private let callbacks: CallbackWatchdog
    private let snapshots: any SnapshotReclaiming
    private let scheduler: any TimerScheduler
    private let clock: any MonotonicClock
    private let onCallbackReturned: @Sendable () -> Void
    private let onTrip: @Sendable (TapTrip) -> Void
    private let state = Mutex(State())

    /// `onCallbackReturned` maps to `LifecycleInput.callbackExited`, `onTrip` to `.watchdogTripped`.
    public init(
        tap: any TapControl, callbacks: CallbackWatchdog, snapshots: any SnapshotReclaiming,
        scheduler: any TimerScheduler, clock: any MonotonicClock,
        onCallbackReturned: @escaping @Sendable () -> Void, onTrip: @escaping @Sendable (TapTrip) -> Void
    ) {
        self.tap = tap
        self.callbacks = callbacks
        self.snapshots = snapshots
        self.scheduler = scheduler
        self.clock = clock
        self.onCallbackReturned = onCallbackReturned
        self.onTrip = onTrip
    }

    deinit { state.withLock { $0.cancelAll() } }

    /// Starts the 5 s enabled check. Callbacks seen within the last 2 s arm the callback check at once, because
    /// their activity signal may have arrived before `start()`.
    public func start() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            guard !state.started else { return [] }
            state.started = true
            state.mode = .watching
            state.enabledTimer = scheduler.scheduleRepeating(
                every: Self.enabledCheckInterval, leeway: Self.enabledCheckLeeway
            ) { [weak self] in self?.enabledTick() }
            return armIfRecentlyActive(&state, observation)
        }
        perform(actions)
    }

    public func stop() {
        state.withLock {
            $0.cancelAll()
            $0.started = false
            $0.mode = .watching
        }
    }

    /// The tap's activity signal fired (first callback after 2 s idle): arm the 250 ms check.
    public func callbackActivity() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            guard state.started else { return [] }
            // Callbacks flow only through an enabled tap, so the lifecycle has re-enabled it after a recovery.
            if state.mode == .awaitingReenable && observation.tapEnabled { state.mode = .watching }
            guard state.mode == .watching, state.checkTimer == nil else { return [] }
            return arm(&state, observation)
        }
        perform(actions)
    }

    /// Called on wake, session activation, permission change (PLT-R331).
    public func checkNow() { perform(enabledCheck()) }

    // MARK: - Timers

    private func enabledTick() {
        snapshots.reclaimAll()
        perform(enabledCheck())
    }

    private func enabledCheck() -> [Action] {
        let observation = observe()
        return state.withLock { state -> [Action] in
            guard state.started else { return [] }
            switch state.mode {
            case .watching:
                return observation.tapRunning && !observation.tapEnabled ? [.report(.unexpectedlyDisabled)] : []
            case .tripped:
                return []
            case .stuck:
                guard observation.running == nil else { return [] }
                state.mode = .awaitingReenable
                return [.callbackReturned]
            case .awaitingReenable:
                guard observation.tapEnabled else { return [] }
                state.mode = .watching
                return armIfRecentlyActive(&state, observation)
            }
        }
    }

    /// The repeating 250 ms check (`crossing == false`) or the one-shot crossing check (`crossing == true`).
    private func callbackCheck(crossing: Bool) {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            if crossing { state.crossingTimer = nil }
            guard state.started, state.mode == .watching, state.checkTimer != nil else { return [] }
            return evaluate(&state, observation, mayDisarm: !crossing)
        }
        perform(actions)
    }

    /// ADR 0309: 2 s after the trip, recovery only if the callback has returned.
    private func recoveryCheck() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            state.recoveryTimer = nil
            guard state.started, state.mode == .tripped else { return [] }
            if let running = observation.running {
                state.mode = .stuck
                return [.report(.callbackStuck(microseconds: running / 1_000))]
            }
            state.mode = .awaitingReenable
            return [.callbackReturned]
        }
        perform(actions)
    }

    // MARK: - Decisions (under the lock)

    private func armIfRecentlyActive(_ state: inout State, _ observation: Observation) -> [Action] {
        guard state.checkTimer == nil, let lastEntry = observation.lastEntry,
            observation.now.nanoseconds(since: lastEntry) <= Self.idleNanoseconds
        else { return [] }
        return arm(&state, observation)
    }

    private func arm(_ state: inout State, _ observation: Observation) -> [Action] {
        state.armedAt = observation.now
        state.checkTimer = scheduler.scheduleRepeating(
            every: Self.callbackCheckInterval, leeway: Self.callbackCheckInterval / 10
        ) { [weak self] in self?.callbackCheck(crossing: false) }
        return evaluate(&state, observation, mayDisarm: false)
    }

    private func evaluate(_ state: inout State, _ observation: Observation, mayDisarm: Bool) -> [Action] {
        if let running = observation.running {
            if running > Self.limitNanoseconds { return trip(&state, running: running) }
            if state.crossingTimer == nil {
                let delay = TimeSpan.nanoseconds(Self.limitNanoseconds - running + Self.crossingMargin)
                state.crossingTimer = scheduler.schedule(after: delay, leeway: delay / 10) { [weak self] in
                    self?.callbackCheck(crossing: true)
                }
            }
            return []
        }
        let lastActivity = max(observation.lastEntry ?? .zero, state.armedAt ?? .zero)
        if mayDisarm && observation.now.nanoseconds(since: lastActivity) > Self.idleNanoseconds { state.disarm() }
        return []
    }

    /// PLT-R306: disable the tap (keys flow), report, and check for recovery 2 s later.
    private func trip(_ state: inout State, running: UInt64) -> [Action] {
        state.disarm()
        state.mode = .tripped
        state.recoveryTimer = scheduler.schedule(after: Self.recoveryDelay, leeway: Self.recoveryDelay / 10) {
            [weak self] in self?.recoveryCheck()
        }
        return [.disableTap, .report(.callbackOverLimit(microseconds: running / 1_000))]
    }

    // MARK: - Effects (outside the lock)

    private func observe() -> Observation {
        let now = clock.now()
        return Observation(
            now: now, running: callbacks.runningCallbackDuration(now: now), lastEntry: callbacks.lastCallbackEntry,
            tapRunning: tap.isRunning, tapEnabled: tap.isEnabled)
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .disableTap: tap.setEnabled(false)
            case .report(let trip): onTrip(trip)
            case .callbackReturned: onCallbackReturned()
            }
        }
    }
}
