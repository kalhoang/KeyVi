// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R46, PLT-R1202: health events live in memory and in the rotating log, so a crash or a tap timeout from
// before this launch still appears in the report's last 50 events. The log record of every event reads back
// into the same metadata-only event.

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct EarlierSessionHealthTests {
    static let directory = URL(fileURLWithPath: "/logs/SampleApp")
    static let start = DiagnosticsFixtures.generatedAt
    static let bundle = BundleKey(rawValue: "com.example.Chat")!
    static let rule = RuleID(rawValue: "browser.chromium.addressBar")!

    /// Every kind once, then every detail case, at whole seconds (the log keeps ISO 8601 seconds).
    static func samples(endingBefore end: Date) -> [HealthEvent] {
        let details: [HealthEvent.Detail?] = [
            nil, .count(3), .durationMicroseconds(1_250), .permission(.postEvent, from: .granted, to: .denied),
            .fallback(from: .axReplace, to: .backspaceReplace),
            .secureInput(holder: bundle, holderKind: .application, durationMilliseconds: 900),
            .secureInput(holder: nil, holderKind: nil, durationMilliseconds: 5), .failOpen(.watchdog),
        ]
        let kinds = HealthEvent.Kind.allCases
        let total = kinds.count + details.count
        return (0..<total).map { index in
            let at = end.addingTimeInterval(TimeInterval(index - total))
            if index < kinds.count { return HealthEvent(kind: kinds[index], at: at, bundle: bundle, rule: rule) }
            return HealthEvent(kind: .flush, at: at, detail: details[index - kinds.count])
        }
    }

    @Test func everyHealthRecordReadsBackIntoTheSameEvent() throws {
        for event in Self.samples(endingBefore: Self.start) {
            let record = LogRecord(event: .health(event), level: event.kind.logLevel, at: event.at)
            let encoded = try JSONEncoder.logRecord.encode(record)
            let decoded = try JSONDecoder.logRecord.decode(LogRecord.self, from: encoded)
            #expect(HealthEvent(record: decoded) == event, "\(event.kind) \(String(describing: event.detail))")
        }
    }

    @Test func otherRecordsAreNotHealthEvents() {
        let note = LogRecord(event: .note("ready", category: .lifecycle), level: .info, at: Self.start)
        #expect(HealthEvent(record: note) == nil)
        let unknownKind = LogRecord(
            at: Self.start, level: .notice, category: .tap, code: "health.somethingNew",
            fields: ["eventAt": .string("2027-01-15T08:00:00Z")])
        #expect(HealthEvent(record: unknownKind) == nil)
        let noTime = LogRecord(at: Self.start, level: .notice, category: .tap, code: "health.flush", fields: [:])
        #expect(HealthEvent(record: noTime) == nil)
        let badDetail = LogRecord(
            at: Self.start, level: .notice, category: .tap, code: "health.flush",
            fields: ["eventAt": .string("2027-01-15T08:00:00Z"), "count": .string("many")])
        #expect(HealthEvent(record: badDetail)?.detail == nil)
    }

    @Test func loggerReadsTheEarlierSessionsEventsAcrossRotatedFiles() throws {
        let fileSystem = InMemoryFileSystem(now: { Self.start })
        let earlier = Self.samples(endingBefore: Self.start)
        // A previous session wrote these, with small files so they rotate (PLT-R903).
        let previous = DiagnosticsLogger(
            policy: LogStorePolicy(directory: Self.directory, maxFileBytes: 1_200), fileSystem: fileSystem,
            clock: FixedWallClock(Self.start.addingTimeInterval(-3_600)), subsystem: "test.diagnostics")
        for event in earlier {
            previous.log(.health(event), level: event.kind.logLevel)
            previous.log(.note("ready", category: .lifecycle), level: .info)
        }
        previous.flush()
        let names = try fileSystem.contentsOfDirectory(at: Self.directory).map(\.lastPathComponent)
        #expect(names.count > 1, "the log rotated")

        let current = DiagnosticsLogger(
            policy: LogStorePolicy(directory: Self.directory, maxFileBytes: 1_200), fileSystem: fileSystem,
            clock: FixedWallClock(Self.start), subsystem: "test.diagnostics")
        let now = HealthEvent(kind: .tapTimeout, at: Self.start.addingTimeInterval(5))
        current.log(.health(now), level: .error)
        current.flush()
        let restored = current.earlierSessionHealthEvents(limit: 50)
        let kept = Array(earlier.suffix(restored.count))
        #expect(!restored.isEmpty)
        #expect(restored == kept, "newest last, only events from before this session")
        #expect(!restored.contains(now))
        #expect(current.earlierSessionHealthEvents(limit: 3) == Array(kept.suffix(3)))
        #expect(current.earlierSessionHealthEvents(limit: 0).isEmpty)
    }

    static func logger(at date: Date, _ fileSystem: InMemoryFileSystem, maxFileBytes: Int = 1_000_000)
        -> DiagnosticsLogger
    {
        DiagnosticsLogger(
            policy: LogStorePolicy(directory: directory, maxFileBytes: maxFileBytes), fileSystem: fileSystem,
            clock: FixedWallClock(date), subsystem: "test.diagnostics")
    }

    /// PLT-R1202: the 24-hour tap counters need more than the 50 listed events, so the earlier sessions' events
    /// are kept up to the in-memory ring's capacity.
    @Test func theEarlierSessionsKeepAsManyEventsAsTheRing() {
        let fileSystem = InMemoryFileSystem(now: { Self.start })
        let previous = Self.logger(at: Self.start.addingTimeInterval(-3_600), fileSystem)
        let earlier = (0..<300).map {
            HealthEvent(kind: .echoLoss, at: Self.start.addingTimeInterval(Double($0 - 400)))
        }
        for event in earlier { previous.log(.health(event), level: event.kind.logLevel) }
        previous.flush()
        let current = Self.logger(at: Self.start, fileSystem)
        let restored = current.earlierSessionHealthEvents(limit: HealthEventLog.defaultCapacity)
        #expect(restored == Array(earlier.suffix(HealthEventLog.defaultCapacity)))
    }

    /// Only health records are decoded; any number of other records in the files does not change the result.
    @Test func otherRecordsInTheFilesAreSkipped() {
        let fileSystem = InMemoryFileSystem(now: { Self.start })
        let previous = Self.logger(at: Self.start.addingTimeInterval(-3_600), fileSystem, maxFileBytes: 4_000_000)
        let events = (0..<3).map { HealthEvent(kind: .tapTimeout, at: Self.start.addingTimeInterval(Double($0 - 10))) }
        for index in 0..<10_000 {
            if index % 4_000 == 0 {
                let event = events[index / 4_000]
                previous.log(.health(event), level: event.kind.logLevel)
            }
            previous.log(.note("ready", category: .lifecycle), level: .info)
        }
        previous.flush()
        let current = Self.logger(at: Self.start, fileSystem)
        #expect(current.earlierSessionHealthEvents(limit: 50) == events)
    }

    /// PRD-R46 without a pause when a report opens: the launch's maintenance pass reads the earlier sessions'
    /// events on the logger's queue, so the first report finds them already loaded.
    @Test func maintenanceLoadsTheEarlierSessionsEventsAhead() throws {
        let fileSystem = InMemoryFileSystem(now: { Self.start })
        let previous = Self.logger(at: Self.start.addingTimeInterval(-3_600), fileSystem)
        let event = HealthEvent(kind: .tapTimeout, at: Self.start.addingTimeInterval(-60))
        previous.log(.health(event), level: .error)
        previous.flush()
        let current = Self.logger(at: Self.start, fileSystem)
        current.maintain()
        current.flush()
        for url in try fileSystem.contentsOfDirectory(at: Self.directory) { try fileSystem.removeItem(at: url) }
        #expect(current.earlierSessionHealthEvents(limit: 50) == [event], "read before the files went away")
    }

    @Test func theReportListsEarlierThenCurrentEventsOnce() {
        let earlier = Self.samples(endingBefore: Self.start)
        let current = [
            HealthEvent(kind: .tapTimeout, at: Self.start.addingTimeInterval(1)),
            HealthEvent(kind: .flush, at: Self.start.addingTimeInterval(2), detail: .count(1)),
        ]
        let list = HealthEvent.reportList(earlier: earlier, current: current, limit: 50)
        #expect(list == Array((earlier + current).suffix(50)))
        #expect(HealthEvent.reportList(earlier: earlier, current: current, limit: 3) == [earlier.last!] + current)
        // An event of this session that also came back from the file (a clock set back) is listed once.
        let duplicated = HealthEvent.reportList(earlier: earlier + [current[0]], current: current, limit: 50)
        #expect(duplicated.filter { $0 == current[0] }.count == 1)
        #expect(HealthEvent.reportList(earlier: [], current: [], limit: 50).isEmpty)
    }
}

extension JSONEncoder {
    /// The encoding the log files use.
    fileprivate static var logRecord: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var logRecord: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
