// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `DiagnosticsLogging` fake that keeps events in memory (canary tests read them back). Shared fake:
// integrator-owned (frozen in wave 1).

public import Diagnostics
internal import RealtimeSupport

public final class RecordingLogger: DiagnosticsLogging, Sendable {
    public struct Entry: Sendable {
        public var event: LogEvent
        public var level: LogLevel
    }

    private let storage = Mutex<[Entry]>([])

    public init() {}

    public func log(_ event: LogEvent, level: LogLevel) {
        storage.withLock { $0.append(Entry(event: event, level: level)) }
    }

    public var entries: [Entry] { storage.withLock { $0 } }
}
