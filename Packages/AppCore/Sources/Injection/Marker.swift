// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Self-generated event marker (PLT-R321). Layout of `kCGEventSourceUserData` (Int64):
//   bits 63...24  per-launch random tag (40 bits, CSPRNG)
//   bit  23       kind: 0 = injected or replayed by the worker, 1 = latency probe / guided test input
//   bits 22...0   sequence number (wraps)
// Physical events are never modified (PLT-R321).

internal import AppModel

public struct EventMarker: Sendable, Hashable {
    public let tag: UInt64

    public init(tag: UInt64) { self.tag = tag & 0xFF_FFFF_FFFF }

    /// `SecRandomCopyBytes`.
    public static func random() -> EventMarker { unimplemented() }

    public func userData(sequence: UInt32, probe: Bool) -> Int64 { unimplemented() }
    /// Tap-safe: integer arithmetic only.
    public func classify(_ userData: Int64) -> MarkerMatch { unimplemented() }
}

public enum MarkerMatch: Sendable, Hashable {
    /// An event the worker posted: record the echo and pass it unchanged (PLT-R310 step 2).
    case echo(sequence: UInt32)
    /// A probe or guided-test event: process as physical, route metrics to probe histograms (PLT-R810).
    case probe(sequence: UInt32)
    /// Physical (or another tool's) event.
    case foreign
}

