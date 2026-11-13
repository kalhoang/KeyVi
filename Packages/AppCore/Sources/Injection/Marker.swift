// SPDX-License-Identifier: GPL-3.0-or-later
//
// Self-generated event marker (PLT-R321). Layout of `kCGEventSourceUserData` (Int64):
//   bits 63...24  per-launch random tag (40 bits, CSPRNG, never zero)
//   bit  23       kind: 0 = injected or replayed by the worker, 1 = latency probe / guided test input
//   bits 22...0   event sequence number, incremented by the worker for every posted event (wraps)
// Physical events are never modified (PLT-R321). Implemented in the skeleton (ADR 0313); W1-D owns it.

internal import AppModel

public struct EventMarker: Sendable, Hashable {
    public static let tagMask: UInt64 = 0xFF_FFFF_FFFF
    public static let sequenceMask: UInt32 = 0x7F_FFFF
    private static let probeBit: UInt64 = 1 << 23

    public let tag: UInt64

    /// `tag` is masked to 40 bits and must not be zero (physical events usually carry user data 0).
    public init(tag: UInt64) {
        precondition(tag & Self.tagMask != 0, "marker tag must be non-zero")
        self.tag = tag & Self.tagMask
    }

    /// 40 bits from `SystemRandomNumberGenerator` (a CSPRNG on Darwin: `arc4random_buf`), retried if zero.
    public static func random() -> EventMarker {
        var generator = SystemRandomNumberGenerator()
        var tag: UInt64 = 0
        while tag == 0 { tag = generator.next() & tagMask }
        return EventMarker(tag: tag)
    }

    public func userData(sequence: UInt32, probe: Bool) -> Int64 {
        let bits = (tag << 24) | (probe ? Self.probeBit : 0) | UInt64(sequence & Self.sequenceMask)
        return Int64(bitPattern: bits)
    }

    /// Tap-safe: integer arithmetic only.
    @inline(__always)
    public func classify(_ userData: Int64) -> MarkerMatch {
        let bits = UInt64(bitPattern: userData)
        guard bits >> 24 == tag else { return .foreign }
        let sequence = UInt32(truncatingIfNeeded: bits) & Self.sequenceMask
        return bits & Self.probeBit == 0 ? .echo(sequence: sequence) : .probe(sequence: sequence)
    }
}

public enum MarkerMatch: Sendable, Hashable {
    /// An event the worker posted: record the echo and pass it unchanged (PLT-R310 step 2).
    case echo(sequence: UInt32)
    /// A probe or guided-test event: process as physical, route metrics to probe histograms (PLT-R810).
    case probe(sequence: UInt32)
    /// Physical (or another tool's) event.
    case foreign
}
