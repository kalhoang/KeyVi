// SPDX-License-Identifier: GPL-3.0-or-later
//
// Delayed-write timers for the settings store (PLT-R1003 1 s debounce, PLT-R392 5 s for app modes).
//
// ADR 0313 rule 4 asks time-dependent code to take `any TimerScheduler`. SettingsStore was written against
// AppModel only, so this module declares the one-shot subset it needs; TestSupport adapts `ManualScheduler` to it
// (`TimerDebounceScheduler`) and production uses `DispatchDebounceScheduler` on the utility queue. SettingsStore
// now imports RealtimeSupport for `TimeSpan` (ADR 0315), so this protocol can become a thin alias of
// `TimerScheduler` in a later change.

public import Dispatch
public import RealtimeSupport

/// A pending one-shot timer. `cancel()` is idempotent and callable from any thread.
public protocol DebounceTimer: Sendable {
    func cancel()
}

/// Runs a handler once after a delay. Handlers may run on any thread; the store hops to its own queue.
public protocol DebounceScheduler: Sendable {
    func schedule(after delay: TimeSpan, _ handler: @escaping @Sendable () -> Void) -> any DebounceTimer
}

/// Production scheduler: one-shot `DispatchSourceTimer`s on one serial queue (the utility queue, PLT-R203).
public final class DispatchDebounceScheduler: DebounceScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after delay: TimeSpan, _ handler: @escaping @Sendable () -> Void) -> any DebounceTimer {
        DispatchDebounceTimer(queue: queue, delay: Self.interval(delay), handler: handler)
    }

    /// A saturated span (`TimeSpan` clamps at about 292 years) never fires.
    static func interval(_ duration: TimeSpan) -> DispatchTimeInterval {
        duration.nanoseconds == .max ? .never : duration.dispatchInterval
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
