// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Deterministic `TimerScheduler` over `ManualClock` (ADR 0313). Tests advance virtual time; due timers fire
// synchronously on the caller's thread in deadline order. Shared fake: integrator-owned (frozen in wave 1).

public import RealtimeSupport

public final class ManualScheduler: TimerScheduler, Sendable {
    private struct Entry {
        var id: UInt64
        var deadline: UInt64
        var interval: UInt64?
        var leeway: TimeSpan
        var handler: @Sendable () -> Void
    }

    private final class Timer: ScheduledTimer {
        let id: UInt64
        let owner: ManualScheduler
        init(id: UInt64, owner: ManualScheduler) {
            self.id = id
            self.owner = owner
        }
        func cancel() { owner.cancel(id) }
    }

    public let clock: ManualClock
    private let entries = Mutex<[Entry]>([])
    private let nextID = Atomic<UInt64>(1)

    public init(clock: ManualClock) { self.clock = clock }

    public func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        add(delay: delay, interval: nil, leeway: leeway, handler)
    }

    public func scheduleRepeating(
        every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) -> any ScheduledTimer {
        add(delay: interval, interval: interval, leeway: leeway, handler)
    }

    /// Advances the clock by `duration`, firing every timer that becomes due, in deadline order (a repeating
    /// timer fires once per elapsed interval).
    public func advance(by duration: TimeSpan) {
        let target = clock.now().nanoseconds &+ duration.unsignedNanoseconds
        while let entry = popDue(before: target) {
            if clock.now().nanoseconds < entry.deadline {
                clock.sleep(until: MonotonicInstant(nanoseconds: entry.deadline))
            }
            entry.handler()
        }
        if clock.now().nanoseconds < target { clock.sleep(until: MonotonicInstant(nanoseconds: target)) }
    }

    /// Timers still scheduled.
    public var pendingCount: Int { entries.withLock { $0.count } }

    /// Intervals of the repeating timers still scheduled (PLT-R803 tests: nothing faster than 2 s at rest).
    public var repeatingIntervals: [TimeSpan] {
        entries.withLock { $0.compactMap { $0.interval.map { TimeSpan.nanoseconds(Int64(clamping: $0)) } } }
    }

    /// Delay until the earliest pending deadline, if any.
    public var nextDeadline: MonotonicInstant? {
        entries.withLock { $0.map(\.deadline).min().map { MonotonicInstant(nanoseconds: $0) } }
    }

    private func add(delay: TimeSpan, interval: TimeSpan?, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        let id = nextID.wrappingAdd(1, ordering: .relaxed).oldValue
        let entry = Entry(
            id: id, deadline: clock.now().nanoseconds &+ delay.unsignedNanoseconds,
            interval: interval.map(\.unsignedNanoseconds), leeway: leeway, handler: handler)
        entries.withLock { $0.append(entry) }
        return Timer(id: id, owner: self)
    }

    private func popDue(before target: UInt64) -> Entry? {
        entries.withLock { entries in
            guard
                let index = entries.indices.filter({ entries[$0].deadline <= target })
                    .min(by: { (entries[$0].deadline, entries[$0].id) < (entries[$1].deadline, entries[$1].id) })
            else { return nil }
            let entry = entries[index]
            if let interval = entry.interval {
                entries[index].deadline = entry.deadline &+ max(interval, 1)
            } else {
                entries.remove(at: index)
            }
            return entry
        }
    }

    fileprivate func cancel(_ id: UInt64) {
        entries.withLock { $0.removeAll { $0.id == id } }
    }
}
