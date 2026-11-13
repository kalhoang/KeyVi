// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Long waits of `compat-harness` (setup `wait` steps up to 60 s, seeded-history settling, the 300 s C1 idle
// window). They suspend instead of blocking a cooperative-pool thread; only the keyboard driver keeps a
// blocking absolute-deadline sleep, because its 13.2 timing needs millisecond precision (workstreams.md
// rule 4: time-dependent code is injectable and tested with ManualClock).

public import RealtimeSupport

public protocol HarnessSleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

/// Runner: `Task.sleep`, which suspends and throws `CancellationError` when the task is cancelled.
public struct TaskSleeper: HarnessSleeper {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

/// Sleeps on a `MonotonicClock`; with `ManualClock` (tests) it advances virtual time instead of waiting.
public struct ClockSleeper: HarnessSleeper {
    private let clock: any MonotonicClock
    public init(clock: any MonotonicClock) { self.clock = clock }
    public func sleep(nanoseconds: UInt64) async throws {
        clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds &+ nanoseconds))
    }
}
