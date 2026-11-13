// SPDX-License-Identifier: GPL-3.0-or-later
//
// The consumer side of `TapLogRing` (PLT-R304 "fixed-size records into a lock-free ring", PLT-R903): on the
// utility queue it turns the tap's records into health events and typed log events. Records carry the tap's
// monotonic time; health events carry wall-clock dates, so each record is dated by its distance from "now" on
// both clocks. Workstream W2-A (owner assigned by the integrator after wave 1).

public import AppModel
public import Diagnostics
public import Foundation
public import RealtimeSupport

/// Converts a monotonic instant into a wall-clock date by anchoring both clocks at the moment of the drain.
/// Uptime does not advance during sleep while the wall clock does, so the anchor is taken per drain, not once.
public struct MonotonicToWallClock: Sendable {
    public var monotonicNow: MonotonicInstant
    public var wallNow: Date

    public init(monotonicNow: MonotonicInstant, wallNow: Date) {
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
    }

    /// A record from the future (clock skew between threads) is dated "now".
    public func date(of instant: MonotonicInstant) -> Date {
        let ago = monotonicNow.nanoseconds(since: instant)
        return wallNow.addingTimeInterval(-Double(ago) / 1_000_000_000)
    }
}

/// What a drain produced (tests and the diagnostics window's counters).
public struct TapLogDrainResult: Sendable, Hashable {
    public var records = 0
    public var healthEvents = 0
    /// Records the tap could not push because the ring was full, since the previous drain.
    public var newlyDropped: UInt64 = 0
}

/// Drains the ring. `clock` must be the clock the tap stamps records with (`MachClock` in production).
public final class TapLogDrainer: Sendable {
    private let ring: TapLogRing
    private let health: HealthEventLog
    private let logger: any DiagnosticsLogging
    private let clock: any MonotonicClock
    private let wallClock: any WallClock
    private let reportedDrops = Mutex<UInt64>(0)

    public init(
        ring: TapLogRing, health: HealthEventLog, logger: any DiagnosticsLogging, clock: any MonotonicClock,
        wallClock: any WallClock
    ) {
        self.ring = ring
        self.health = health
        self.logger = logger
        self.clock = clock
        self.wallClock = wallClock
    }

    /// Utility queue (single consumer of the ring).
    @discardableResult
    public func drain() -> TapLogDrainResult {
        let anchor = MonotonicToWallClock(monotonicNow: clock.now(), wallNow: wallClock.now())
        var result = TapLogDrainResult()
        ring.drain { record in
            result.records += 1
            if let event = Self.healthEvent(for: record, anchor: anchor) {
                health.record(event)
                result.healthEvents += 1
            } else if let (message, level) = Self.logLine(for: record.code) {
                logger.log(.note(message, category: .tap), level: level)
            }
        }
        let dropped = ring.droppedCount
        result.newlyDropped = reportedDrops.withLock { reported in
            defer { reported = dropped }
            return dropped &- reported
        }
        if result.newlyDropped > 0 { logger.log(.note("tap log records dropped", category: .tap), level: .notice) }
        return result
    }

    /// Codes that become health events (PLT-R1206). The tap-disabled and re-enabled codes are not among them:
    /// the lifecycle records those itself when it runs the PLT-R330 procedure, and one disable must count once.
    static func healthEvent(for record: TapLogRecord, anchor: MonotonicToWallClock) -> HealthEvent? {
        let at = anchor.date(of: record.at)
        switch record.code {
        case .echoMissing:
            // `a` = consecutive misses (ADR 0311).
            return HealthEvent(kind: .echoLoss, at: at, detail: .count(Int(clamping: record.a)))
        case .flushRequested:
            return HealthEvent(kind: .flush, at: at, detail: .count(Int(clamping: max(record.a, 1))))
        case .tapDisabledByTimeout, .tapDisabledByUserInput, .tapReenabled, .jobQueueFull, .secureInputResumedByKey,
            .layoutMismatch, .unknownEventType, .callbackOverBudget:
            return nil
        }
    }

    /// Fixed messages for the codes that are not health events (PLT-R902: `StaticString` only, no payload).
    static func logLine(for code: TapLogCode) -> (StaticString, LogLevel)? {
        switch code {
        case .tapDisabledByTimeout: ("tap disabled by timeout", .info)
        case .tapDisabledByUserInput: ("tap disabled by user input", .info)
        case .tapReenabled: ("tap re-enabled", .info)
        case .jobQueueFull: ("job queue full, key passed through", .error)
        case .secureInputResumedByKey: ("secure input resumed by key evidence", .info)
        case .layoutMismatch: ("layout table disagrees with the event", .debug)
        case .unknownEventType: ("unknown event type", .debug)
        // The watchdog trip itself is recorded by the lifecycle (PLT-R306); this is the T1 budget note.
        case .callbackOverBudget: ("tap callback over budget", .notice)
        case .echoMissing, .flushRequested: nil
        }
    }
}
