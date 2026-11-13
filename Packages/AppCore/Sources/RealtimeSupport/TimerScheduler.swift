// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Timers for host services (docs/decisions/0313-testability-seams.md). Every periodic or delayed action of the
// permission monitor, secure-input monitor, tap watchdog and lifecycle backoff goes through `TimerScheduler`,
// so tests drive them deterministically with `ManualScheduler` (TestSupport) instead of sleeping.
// Never used on the tap thread (PLT-R305).

public import Dispatch
internal import Synchronization

/// A scheduled one-shot or repeating timer. `cancel()` is idempotent and callable from any thread. A one-shot
/// timer stays alive until it fires or is cancelled; a repeating timer is cancelled when its last reference
/// goes away, so owners keep it in a property.
public protocol ScheduledTimer: Sendable {
    func cancel()
}

/// Schedules handlers on the scheduler's own queue (production: the utility queue, PLT-R203).
public protocol TimerScheduler: Sendable {
    /// Runs `handler` once after `delay`. `leeway` lets the OS coalesce wakeups (PLT-R803).
    func schedule(after delay: Duration, leeway: Duration, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    /// Runs `handler` every `interval`, first after one interval.
    func scheduleRepeating(every interval: Duration, leeway: Duration, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
}

/// Production scheduler backed by `DispatchSourceTimer` on one serial queue.
public final class DispatchTimerScheduler: TimerScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after delay: Duration, leeway: Duration, _ handler: @escaping @Sendable () -> Void)
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
        every interval: Duration, leeway: Duration, _ handler: @escaping @Sendable () -> Void
    ) -> any ScheduledTimer {
        let timer = DispatchTimer(queue: queue)
        timer.start(deadline: .now() + interval.dispatchInterval, repeating: interval, leeway: leeway, handler)
        return timer
    }
}

private final class DispatchTimer: ScheduledTimer {
    private let source: any DispatchSourceTimer
    private let cancelled = Atomic<Bool>(false)

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    deinit { cancel() }

    func start(
        deadline: DispatchTime, repeating: Duration?, leeway: Duration, _ handler: @escaping @Sendable () -> Void
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

extension Duration {
    /// Nanosecond-precision conversion for Dispatch APIs.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(clamping: nanoseconds))
    }
}
