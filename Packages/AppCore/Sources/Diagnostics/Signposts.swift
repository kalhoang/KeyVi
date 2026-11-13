// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel

/// `os_signpost` intervals around the callback, job execution and AX calls in all builds (PLT-R802); zero cost
/// when not recording. Interval names are static strings.
public struct PlatformSignposts: Sendable {
    public enum Interval: Sendable { case tapCallback, injectionJob, axCall }
    public struct Token: Sendable { let raw: UInt64 }

    public init(subsystem: String) { unimplemented() }
    public func begin(_ interval: Interval) -> Token { unimplemented() }
    public func end(_ interval: Interval, _ token: Token) { unimplemented() }
}

