// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R903: JSON lines in `~/Library/Logs/<folder>/`, dir 0700, files 0600, 5 files of 1 MB, 14 days.
// PRD-R46: health events are mirrored into the file.

import AppModel
import Foundation
import Synchronization
import Testing

@testable import Diagnostics
@testable import TestSupport

private struct LoggerFixture {
    static let directory = URL(fileURLWithPath: "/logs/SampleApp")
    let clock = FixedWallClock(DiagnosticsFixtures.generatedAt)
    let fileSystem: InMemoryFileSystem
    let logger: DiagnosticsLogger

    init(maxFileBytes: Int = 1_000_000) {
        let clock = self.clock
        fileSystem = InMemoryFileSystem(now: { clock.now() })
        logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: Self.directory, maxFileBytes: maxFileBytes), fileSystem: fileSystem,
            clock: clock, subsystem: "test.diagnostics")
    }

    func lines(_ name: String = "diagnostics.jsonl") -> [String] {
        let node = fileSystem.nodes[Self.directory.appendingPathComponent(name).path]
        return String(decoding: node?.data ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    var fileNames: [String] {
        fileSystem.nodes.keys.filter { $0.hasPrefix(Self.directory.path + "/") }
            .map { String($0.dropFirst(Self.directory.path.count + 1)) }.sorted()
    }
}

@Suite struct DiagnosticsLoggerTests {
    @Test func writesOneDecodableJSONLinePerEvent() throws {
        let fixture = LoggerFixture()
        fixture.logger.log(.permission(.postEvent, .denied), level: .error)
        fixture.logger.log(.note("ready", category: .lifecycle), level: .info)
        fixture.logger.flush()
        let lines = fixture.lines()
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(LogRecord.self, from: Data(lines[0].utf8))
        #expect(first.code == "permission.state")
        #expect(first.level == .error)
        #expect(first.at == DiagnosticsFixtures.generatedAt)
        #expect(first.fields["state"] == .string("denied"))
    }

    @Test func directoryIsOwnerOnlyAndFilesAre0600() {
        let fixture = LoggerFixture()
        fixture.logger.log(.lifecycle(.tapCreated), level: .info)
        fixture.logger.flush()
        let nodes = fixture.fileSystem.nodes
        #expect(nodes[LoggerFixture.directory.path]?.permissions == .ownerOnlyDirectory)
        #expect(
            nodes[LoggerFixture.directory.appendingPathComponent("diagnostics.jsonl").path]?.permissions
                == .ownerOnlyFile)
    }

    @Test func rotatesIntoAtMostFiveFiles() {
        let fixture = LoggerFixture(maxFileBytes: 400)
        for index in 0..<200 {
            fixture.logger.log(.settings(.imported(macros: index, appEntries: 0, overrides: 0)), level: .info)
        }
        fixture.logger.flush()
        #expect(
            fixture.fileNames == [
                "diagnostics.1.jsonl", "diagnostics.2.jsonl", "diagnostics.3.jsonl", "diagnostics.4.jsonl",
                "diagnostics.jsonl",
            ])
        for name in fixture.fileNames {
            let size =
                fixture.fileSystem.nodes[LoggerFixture.directory.appendingPathComponent(name).path]?.data?.count ?? 0
            #expect(size <= 400)
        }
        // The newest record is in the current file, older ones moved up.
        #expect(fixture.lines().last?.contains("\"macros\":199") == true)
        #expect(fixture.lines("diagnostics.1.jsonl").isEmpty == false)
    }

    @Test func maintainDeletesFilesOlderThanFourteenDays() {
        let fixture = LoggerFixture(maxFileBytes: 400)
        for index in 0..<10 {
            fixture.logger.log(.settings(.imported(macros: index, appEntries: 0, overrides: 0)), level: .info)
        }
        fixture.logger.flush()
        let rotated = fixture.fileNames
        #expect(rotated.count > 1)
        fixture.clock.advance(by: 13 * 86_400)
        fixture.logger.maintain()
        fixture.logger.flush()
        #expect(fixture.fileNames == rotated)
        fixture.clock.advance(by: 2 * 86_400)
        fixture.logger.maintain()
        fixture.logger.log(.lifecycle(.terminating), level: .notice)
        fixture.logger.flush()
        #expect(fixture.fileNames == ["diagnostics.jsonl"])
        #expect(fixture.lines().count == 1)
    }

    @Test func maintainRemovesRotatedFilesBeyondTheLimitAndIgnoresOtherFiles() throws {
        let fixture = LoggerFixture()
        let directory = LoggerFixture.directory
        for name in ["diagnostics.7.jsonl", "captures", "notes.txt", "diagnostics.x.jsonl", "diagnostics.1.2.jsonl"] {
            try fixture.fileSystem.writeAtomically(
                Data("x".utf8), to: directory.appendingPathComponent(name), permissions: .ownerOnlyFile)
        }
        fixture.logger.maintain()
        fixture.logger.flush()
        #expect(fixture.fileNames == ["captures", "diagnostics.1.2.jsonl", "diagnostics.x.jsonl", "notes.txt"])
    }

    @Test func writeFailuresAreCountedNotThrown() {
        let memory = InMemoryFileSystem()
        let failing = FailingAppendFileSystem(base: memory, failures: 1)
        let logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: LoggerFixture.directory), fileSystem: failing,
            clock: FixedWallClock(), subsystem: "test.diagnostics")
        logger.log(.lifecycle(.tapRemoved), level: .info)
        logger.log(.lifecycle(.tapCreated), level: .info)
        logger.flush()
        #expect(logger.failedWrites == 1)
        let data = memory.nodes[LoggerFixture.directory.appendingPathComponent("diagnostics.jsonl").path]?.data
        #expect(String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\n").count == 1)
    }

    @Test func healthEventLogMirrorsIntoTheLogger() {
        let fixture = LoggerFixture()
        let health = HealthEventLog(capacity: 4, mirror: fixture.logger)
        health.record(HealthEvent(kind: .watchdogTrip, at: DiagnosticsFixtures.generatedAt))
        health.record(HealthEvent(kind: .tapReenabled, at: DiagnosticsFixtures.generatedAt))
        fixture.logger.flush()
        let lines = fixture.lines()
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"code\":\"health.watchdogTrip\""))
        #expect(lines[0].contains("\"level\":3"))  // error
        #expect(lines[1].contains("\"level\":2"))  // notice
        #expect(health.recent(limit: 5).count == 2)
    }

    @Test func healthEventLogWithoutMirrorStillRecords() {
        let recorder = RecordingLogger()
        let health = HealthEventLog(capacity: 2, mirror: recorder)
        health.record(HealthEvent(kind: .flush, at: .distantPast))
        #expect(recorder.entries.count == 1)
        #expect(HealthEventLog().recent(limit: 1).isEmpty)
    }

    @Test func unifiedLogMessageCarriesOnlyTheFields() {
        let record = LogRecord(event: .permission(.listenEvent, .unknown), level: .info, at: .distantPast)
        #expect(UnifiedLogMirror.fieldsText(record.fields) == "{\"permission\":\"listenEvent\",\"state\":\"unknown\"}")
        UnifiedLogMirror(subsystem: "test.diagnostics").write(record)
    }

    /// Real files: POSIX permissions come out as 0700 and 0600 through `LocalFileSystem`.
    @Test func localFileSystemGetsOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w1a-logs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Logs")
        let logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: directory), fileSystem: LocalFileSystem(), clock: SystemWallClock(),
            subsystem: "test.diagnostics")
        logger.log(.lifecycle(.tapCreated), level: .info)
        logger.flush()
        let fileSystem = LocalFileSystem()
        #expect(try fileSystem.attributes(at: directory).permissions == .ownerOnlyDirectory)
        #expect(
            try fileSystem.attributes(at: directory.appendingPathComponent("diagnostics.jsonl")).permissions
                == .ownerOnlyFile)
    }
}

/// Wraps a file system and fails the first `failures` appends (disk full, revoked folder).
final class FailingAppendFileSystem: FileSystem {
    let base: any FileSystem
    private let remaining: Mutex<Int>

    init(base: any FileSystem, failures: Int) {
        self.base = base
        remaining = Mutex(failures)
    }

    func append(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        let fail = remaining.withLock { count in
            defer { count = max(0, count - 1) }
            return count > 0
        }
        if fail { throw FileSystemError.ioFailure(path: url.path, errno: 28) }
        try base.append(data, to: url, permissions: permissions)
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func readData(at url: URL, maxBytes: Int) throws -> Data { try base.readData(at: url, maxBytes: maxBytes) }
    func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws {
        try base.writeAtomically(data, to: url, permissions: permissions)
    }
    func createDirectory(at url: URL, permissions: FilePermissions) throws {
        try base.createDirectory(at: url, permissions: permissions)
    }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func attributes(at url: URL) throws -> FileAttributes { try base.attributes(at: url) }
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        try base.setExcludedFromBackup(excluded, at: url)
    }
}
