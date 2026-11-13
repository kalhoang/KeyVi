// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

/// PLT-R903: `~/Library/Logs/<folder>/`, dir 0700, files 0600, JSON lines, 5 files of 1 MB, 14 days.
public struct LogStorePolicy: Sendable, Hashable {
    public var directory: URL
    public var maxFileBytes: Int
    public var maxFiles: Int
    public var retention: TimeInterval

    public init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 5, retention: TimeInterval = 14 * 86_400) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.retention = retention
    }
}

/// One JSON line in the log file.
public struct LogRecord: Sendable, Codable {
    public var at: Date
    public var level: LogLevel
    public var category: LogCategory
    /// Stable machine code of the event, for example `health.flush` or `settings.recoveredFromBackup`.
    public var code: String
    /// Typed metadata fields rendered from the event (bundle keys, rule IDs, counts, durations).
    public var fields: [String: JSONValue]
}

/// Production logger: renders `LogEvent` to `LogRecord`, writes JSON lines on the utility queue, mirrors to
/// the unified log through `os.Logger` with default private redaction for dynamic values (PLT-R902).
public final class DiagnosticsLogger: DiagnosticsLogging {
    public init(policy: LogStorePolicy, fileSystem: any FileSystem, clock: any WallClock, subsystem: String) {
        unimplemented()
    }

    public func log(_ event: LogEvent, level: LogLevel) { unimplemented() }
    /// Rotation and 14-day retention; scheduled by the utility queue at launch and every 6 hours.
    public func maintain() { unimplemented() }
}
