// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

/// PLT-R903: `~/Library/Logs/<folder>/`, dir 0700, files 0600, JSON lines, 5 files of 1 MB, 14 days.
public struct LogStorePolicy: Sendable, Hashable {
    public var directory: URL
    public var maxFileBytes: Int
    public var maxFiles: Int
    public var retention: TimeInterval

    public init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 5, retention: TimeInterval = 14 * 86_400)
    {
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

    public init(at: Date, level: LogLevel, category: LogCategory, code: String, fields: [String: JSONValue]) {
        self.at = at
        self.level = level
        self.category = category
        self.code = code
        self.fields = fields
    }

    /// Renders a typed event (PLT-R902). The only way application code produces a record.
    public init(event: LogEvent, level: LogLevel, at: Date) {
        let rendered = event.rendered
        self.init(at: at, level: level, category: rendered.category, code: rendered.code, fields: rendered.fields)
    }
}

/// Production logger: renders `LogEvent` to `LogRecord`, writes JSON lines on the utility queue, mirrors to
/// the unified log through `os.Logger` with default private redaction for dynamic values (PLT-R902).
public final class DiagnosticsLogger: DiagnosticsLogging {
    private let files: LogFileStore
    private let clock: any WallClock
    private let mirror: UnifiedLogMirror
    private let queue: DispatchQueue

    public init(policy: LogStorePolicy, fileSystem: any FileSystem, clock: any WallClock, subsystem: String) {
        files = LogFileStore(policy: policy, fileSystem: fileSystem)
        self.clock = clock
        mirror = UnifiedLogMirror(subsystem: subsystem)
        queue = DispatchQueue(label: subsystem + ".diagnostics-log", qos: .utility)
    }

    /// Never blocks: the timestamp is taken here, rendering and writing happen on the logger's serial
    /// utility queue. Not called on the tap thread (PLT-R304); the tap writes `TapLogRecord`s instead.
    public func log(_ event: LogEvent, level: LogLevel) {
        let at = clock.now()
        queue.async { [files, mirror] in
            let record = LogRecord(event: event, level: level, at: at)
            mirror.write(record)
            files.append(record)
        }
    }

    /// Rotation and 14-day retention; scheduled by the utility queue at launch and every 6 hours.
    public func maintain() {
        let now = clock.now()
        queue.async { [files] in files.maintain(now: now) }
    }

    /// Waits until every record logged before this call is written. For shutdown and tests; never call it on
    /// the tap thread or from inside a logging call.
    public func flush() {
        queue.sync {}
    }

    /// Writes that failed since launch (disk full, permissions). Logging never throws to its callers.
    public var failedWrites: Int { files.failedWrites }
}
