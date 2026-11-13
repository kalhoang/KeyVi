// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
internal import os

/// `os_signpost` intervals around the callback, job execution and AX calls in all builds (PLT-R802); zero cost
/// when not recording. Interval names are static strings.
///
/// Tap-safe: when no tool records signposts `begin` and `end` are one flag check. While recording they use the
/// format-less `os_signpost` call and a generated ID, neither of which allocates (checked by the W1-A
/// allocation test). Signposts carry no metadata at all, only the interval name.
public struct PlatformSignposts: Sendable {
    public enum Interval: Sendable { case tapCallback, injectionJob, axCall }
    public struct Token: Sendable { let raw: UInt64 }

    private let log: OSLog

    public init(subsystem: String) {
        log = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    }

    /// A token for `end`. Its value is 0 when signposts are not being recorded.
    @inline(__always)
    public func begin(_ interval: Interval) -> Token {
        guard log.signpostsEnabled else { return Token(raw: 0) }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: interval.name, signpostID: id)
        return Token(raw: id.rawValue)
    }

    @inline(__always)
    public func end(_ interval: Interval, _ token: Token) {
        guard token.raw != 0, log.signpostsEnabled else { return }
        os_signpost(.end, log: log, name: interval.name, signpostID: OSSignpostID(token.raw))
    }
}

extension PlatformSignposts.Interval {
    var name: StaticString {
        switch self {
        case .tapCallback: "tapCallback"
        case .injectionJob: "injectionJob"
        case .axCall: "axCall"
        }
    }
}
