// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixed-size records the tap thread writes into a lock-free ring (PLT-R304 "writing fixed-size records into a
// lock-free log ring buffer"). The utility queue drains them into health events and the log file.

internal import AppModel
public import RealtimeSupport

public enum TapLogCode: UInt16, Sendable, Hashable, Codable, BitwiseCopyable {
    case tapDisabledByTimeout = 1
    case tapDisabledByUserInput
    case tapReenabled
    case jobQueueFull
    case flushRequested
    case echoMissing
    case secureInputResumedByKey  // PLT-R398B
    case layoutMismatch  // debug cross-check, keycode + layout only (PLT-R363)
    case unknownEventType
    case callbackOverBudget
    /// PLT-R397A: a keyUp whose keyDown the tap never saw (`a` = key code); the composition was reset.
    case unseenKeyUp
    /// PLT-R340: a focus change found after keys of the active word kept the composition. `a` = microseconds from
    /// the word's last key to the new element's `changedAt`, `b` = from its first key (`UInt64.max`: unknown).
    case lateFocusKept
    /// PLT-R340: such a change ended the word because it was observed too long after the word's last or first key
    /// (same process, readable element, no pause, a compatible engine variant); `a` and `b` as for `lateFocusKept`.
    case lateFocusRefused
}

public struct TapLogRecord: Sendable, Hashable, BitwiseCopyable {
    public var code: TapLogCode
    public var at: MonotonicInstant
    /// Code-specific integers (keycode, counts, durations). Never characters.
    public var a: UInt64
    public var b: UInt64

    public init(code: TapLogCode, at: MonotonicInstant, a: UInt64 = 0, b: UInt64 = 0) {
        self.code = code
        self.at = at
        self.a = a
        self.b = b
    }
}

/// Single producer (tap), single consumer (utility drain). Implemented in the skeleton
/// (docs/decisions/0313-testability-seams.md).
public final class TapLogRing: Sendable {
    private let ring: SPSCRing<TapLogRecord>
    private let dropped = Atomic<UInt64>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int = 1024) {
        var size = 1
        while size < max(1, capacity) { size <<= 1 }
        ring = SPSCRing(capacity: size)
    }

    /// Tap thread. Drops the record (and counts the drop) when full.
    @inline(__always)
    public func push(_ record: TapLogRecord) {
        if !ring.push(record) { dropped.wrappingAdd(1, ordering: .relaxed) }
    }

    /// Utility queue.
    public func drain(_ body: (TapLogRecord) -> Void) {
        while let record = ring.pop() { body(record) }
    }

    public var droppedCount: UInt64 { dropped.load(ordering: .relaxed) }
}
