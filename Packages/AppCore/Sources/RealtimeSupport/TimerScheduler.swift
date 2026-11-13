// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Timers for host services (docs/decisions/0313-testability-seams.md). Every periodic or delayed action of the
// permission monitor, secure-input monitor, tap watchdog and lifecycle backoff goes through `TimerScheduler`,
// so tests drive them deterministically with `ManualScheduler` (TestSupport) instead of sleeping.
// Never used on the tap thread (PLT-R305).

public import Dispatch

/// A scheduled one-shot or repeating timer. `cancel()` is idempotent and callable from any thread. A one-shot
/// timer stays alive until it fires or is cancelled; a repeating timer is cancelled when its last reference
/// goes away, so owners keep it in a property.
public protocol ScheduledTimer: Sendable {
    func cancel()
}

/// Schedules handlers on the scheduler's own queue (production: the utility queue, PLT-R203).
public protocol TimerScheduler: Sendable {
    /// Runs `handler` once after `delay`. `leeway` lets the OS coalesce wakeups (PLT-R803).
    func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    /// Runs `handler` every `interval`, first after one interval.
    func scheduleRepeating(every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
}

/// Production scheduler backed by `DispatchSourceTimer` on one serial queue.
public final class DispatchTimerScheduler: TimerScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        let timer = DispatchTimer(queue: queue)
        timer.start(deadline: .now() + delay.dispatchInterval, repeating: nil, leeway: leeway) {
            timer.cancel()
            handler()
        }
        return timer
    }

    public func scheduleRepeating(
        every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) -> any ScheduledTimer {
        // A zero or negative interval would make the source fire continuously (PLT-R803 "no busy waiting").
        let period = max(interval, Self.minimumRepeatInterval)
        let timer = DispatchTimer(queue: queue)
        timer.start(deadline: .now() + period.dispatchInterval, repeating: period, leeway: leeway, handler)
        return timer
    }

    /// Floor for repeating intervals; callers' own periods are at least 2 s at rest (PLT-R803).
    static let minimumRepeatInterval: TimeSpan = .milliseconds(1)
}

private final class DispatchTimer: ScheduledTimer {
    private let source: any DispatchSourceTimer
    private let cancelled = Atomic<Bool>(false)

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    deinit { cancel() }

    func start(
        deadline: DispatchTime, repeating: TimeSpan?, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) {
        source.schedule(
            deadline: deadline, repeating: repeating?.dispatchInterval ?? .never, leeway: leeway.dispatchInterval)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    func cancel() {
        guard !cancelled.exchange(true, ordering: .sequentiallyConsistent) else { return }
        source.cancel()
    }
}
