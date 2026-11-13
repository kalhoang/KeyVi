// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Delayed-write timers for the settings store (PLT-R1003 1 s debounce, PLT-R392 5 s for app modes).
//
// ADR 0313 rule 4 asks time-dependent code to take `any TimerScheduler`, but SettingsStore depends on AppModel
// only and `Package.swift` is frozen for wave 1, so it cannot import RealtimeSupport. This module declares the
// one-shot subset it needs; TestSupport adapts `ManualScheduler` to it (`TimerDebounceScheduler`) and
// production uses `DispatchDebounceScheduler` on the utility queue. Once the manifest lets SettingsStore import
// RealtimeSupport, this protocol can become a thin alias of `TimerScheduler` (integrator request in the W1-B
// report).

public import Dispatch

/// A pending one-shot timer. `cancel()` is idempotent and callable from any thread.
public protocol DebounceTimer: Sendable {
    func cancel()
}

/// Runs a handler once after a delay. Handlers may run on any thread; the store hops to its own queue.
public protocol DebounceScheduler: Sendable {
    func schedule(after delay: Duration, _ handler: @escaping @Sendable () -> Void) -> any DebounceTimer
}

/// Production scheduler: one-shot `DispatchSourceTimer`s on one serial queue (the utility queue, PLT-R203).
public final class DispatchDebounceScheduler: DebounceScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after delay: Duration, _ handler: @escaping @Sendable () -> Void) -> any DebounceTimer {
        DispatchDebounceTimer(queue: queue, delay: Self.interval(delay), handler: handler)
    }

    static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanoseconds.overflow, seconds >= 0 else { return seconds < 0 ? .nanoseconds(0) : .never }
        return .nanoseconds(Int(clamping: nanoseconds.partialValue + attoseconds / 1_000_000_000))
    }
}

/// Cancelled when fired, when `cancel()` is called, or when its owner drops it.
private final class DispatchDebounceTimer: DebounceTimer {
    private let source: any DispatchSourceTimer

    init(queue: DispatchQueue, delay: DispatchTimeInterval, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, repeating: .never, leeway: .milliseconds(100))
        source.setEventHandler { [source] in
            source.cancel()
            handler()
        }
        source.activate()
    }

    deinit { source.cancel() }

    func cancel() { source.cancel() }
}
