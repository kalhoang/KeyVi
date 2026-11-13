// SPDX-License-Identifier: GPL-3.0-or-later
//
// JSON-lines files of the diagnostics log (PLT-R903, PRD-R46): `diagnostics.jsonl` is written, full files
// rotate to `diagnostics.1.jsonl` ... `diagnostics.<maxFiles-1>.jsonl`, files untouched for longer than the
// retention period are deleted. Directory 0700, files 0600 (PLT-R1001). Used only on the logger's queue.

internal import AppModel
internal import Foundation
internal import RealtimeSupport
internal import os

final class LogFileStore: Sendable {
    static let baseName = "diagnostics"
    static let fileExtension = "jsonl"

    private struct State {
        var currentSize: Int?
        var failedWrites = 0
    }

    let policy: LogStorePolicy
    private let fileSystem: any FileSystem
    private let state = Mutex(State())
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(policy: LogStorePolicy, fileSystem: any FileSystem) {
        self.policy = policy
        self.fileSystem = fileSystem
    }

    var failedWrites: Int { state.withLock { $0.failedWrites } }

    /// `diagnostics.jsonl` for index 0, `diagnostics.<index>.jsonl` for rotated files.
    func fileURL(index: Int) -> URL {
        let name = index == 0 ? Self.baseName : Self.baseName + "." + String(index)
        return policy.directory.appendingPathComponent(name + "." + Self.fileExtension)
    }

    func append(_ record: LogRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        state.withLock { state in
            do {
                let current = fileURL(index: 0)
                var size = try state.currentSize ?? existingSize(of: current)
                if size > 0, size + line.count > policy.maxFileBytes {
                    try rotate()
                    size = 0
                }
                try fileSystem.append(line, to: current, permissions: .ownerOnlyFile)
                state.currentSize = size + line.count
            } catch {
                state.failedWrites += 1
                state.currentSize = nil
            }
        }
    }

    /// Deletes files older than the retention period and rotated files beyond `maxFiles` (PLT-R903).
    func maintain(now: Date) {
        state.withLock { state in
            let cutoff = now.addingTimeInterval(-policy.retention)
            for (url, index) in logFiles() {
                let expired = (try? fileSystem.attributes(at: url)).map { $0.modificationDate < cutoff } ?? false
                guard expired || index >= policy.maxFiles else { continue }
                try? fileSystem.removeItem(at: url)
                if index == 0 { state.currentSize = 0 }
            }
        }
    }

    /// Health events logged before `cutoff`, newest last, at most `limit` (PRD-R46). Files are read newest first
    /// and only until `limit` events are found; unreadable lines and files are skipped.
    func healthEvents(before cutoff: Date, limit: Int) -> [HealthEvent] {
        guard limit > 0 else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var newestFirst: [HealthEvent] = []
        return state.withLock { _ in
            for index in 0..<max(policy.maxFiles, 1) where newestFirst.count < limit {
                let url = fileURL(index: index)
                guard fileSystem.fileExists(at: url),
                    let data = try? fileSystem.readData(at: url, maxBytes: Self.readLimit(policy))
                else { continue }
                let events = data.split(separator: 0x0A).compactMap { line -> HealthEvent? in
                    // Only lines that can hold a health record are decoded (most lines are other records).
                    guard line.range(of: Self.healthMarker) != nil else { return nil }
                    return (try? decoder.decode(LogRecord.self, from: Data(line))).flatMap(HealthEvent.init(record:))
                }
                newestFirst += events.filter { $0.at < cutoff }.reversed()
            }
            return Array(newestFirst.prefix(limit).reversed())
        }
    }

    /// Every health record's code starts with this (`health.<kind>`); a line without it is not a health event.
    private static let healthMarker = Data("\"health.".utf8)

    /// A file can exceed the rotation size by its last line; anything far larger is not a log file of ours.
    private static func readLimit(_ policy: LogStorePolicy) -> Int { max(policy.maxFileBytes, 1) * 2 }

    private func existingSize(of url: URL) throws -> Int {
        if fileSystem.fileExists(at: url) { return try fileSystem.attributes(at: url).size }
        try fileSystem.createDirectory(at: policy.directory, permissions: .ownerOnlyDirectory)
        return 0
    }

    /// Shifts every file one index up; the oldest one falls off so at most `maxFiles` files exist.
    private func rotate() throws {
        let oldest = fileURL(index: max(policy.maxFiles - 1, 0))
        if fileSystem.fileExists(at: oldest) { try fileSystem.removeItem(at: oldest) }
        var index = policy.maxFiles - 2
        while index >= 0 {
            let source = fileURL(index: index)
            if fileSystem.fileExists(at: source) { try fileSystem.moveItem(at: source, to: fileURL(index: index + 1)) }
            index -= 1
        }
    }

    /// The log files in the directory with their rotation index; other files (captures) are ignored.
    private func logFiles() -> [(URL, Int)] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: policy.directory) else { return [] }
        return entries.compactMap { url in
            let parts = url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == Self.baseName, parts.last.map(String.init) == Self.fileExtension
            else { return nil }
            switch parts.count {
            case 2: return (url, 0)
            case 3: return Int(parts[1]).map { (url, $0) }
            default: return nil
            }
        }
    }
}

/// Mirror of every record into the unified log (PLT-R902). The code is public (a fixed machine code), the
/// metadata fields keep the default private redaction of `os.Logger` interpolation.
struct UnifiedLogMirror: Sendable {
    private let loggers: [LogCategory: Logger]

    init(subsystem: String) {
        var loggers: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        self.loggers = loggers
    }

    func write(_ record: LogRecord) {
        guard let logger = loggers[record.category] else { return }
        let code = record.code
        let level = record.level.osLogType
        let fields = Self.fieldsText(record.fields)
        // The typed record bridge: the code is a fixed machine code, the fields keep private redaction.
        logger.log(level: level, "\(code, privacy: .public) \(fields)")  // lint:allow-log-interpolation bridge
    }

    /// Compact, key-sorted JSON of the metadata fields.
    static func fieldsText(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(fields) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }
}
