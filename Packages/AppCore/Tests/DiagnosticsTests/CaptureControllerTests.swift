// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R905 / PRD-R46 typing trace: at most 180 s, stops by itself, marks secure-input gaps, 0600 files
// excluded from backup, deleted after 24 hours or right after export or discard.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import Diagnostics
@testable import TestSupport

struct CaptureFixture {
    static let directory = URL(fileURLWithPath: "/logs/SampleApp/captures")
    let wallClock: FixedWallClock
    let clock: ManualClock
    let scheduler: ManualScheduler
    let fileSystem: InMemoryFileSystem
    let controller: CaptureController

    static func make() -> CaptureFixture {
        let wallClock = FixedWallClock(DiagnosticsFixtures.generatedAt)
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let fileSystem = InMemoryFileSystem(now: { wallClock.now() })
        let controller = CaptureController(
            directory: directory, fileSystem: fileSystem, wallClock: wallClock, clock: clock, scheduler: scheduler)
        return CaptureFixture(
            wallClock: wallClock, clock: clock, scheduler: scheduler, fileSystem: fileSystem, controller: controller)
    }

    /// Moves virtual time (monotonic and wall clock together) and fires due timers.
    func advance(seconds: Int) {
        wallClock.advance(by: TimeInterval(seconds))
        scheduler.advance(by: .seconds(seconds))
    }

    func key(_ character: String, keyCode: UInt16 = 0, flags: UInt64 = 0) -> CaptureRecord {
        .key(
            KeyCaptureRecord(
                kind: .keyDown, keyCode: keyCode, flags: flags, character: InlineUTF16(character) ?? .empty,
                outcome: .passed, at: clock.now()))
    }

    func lines(_ info: CaptureSessionInfo) -> [CaptureLine] {
        CaptureFiles.decode(fileSystem.nodes[info.file.path]?.data ?? Data())
    }
}

@Suite struct CaptureControllerTests {
    @Test func refusesMoreThanOneHundredEightySeconds() {
        let fixture = CaptureFixture.make()
        #expect(throws: CaptureError.invalidDuration) { try fixture.controller.start(duration: .seconds(181)) }
        #expect(throws: CaptureError.invalidDuration) { try fixture.controller.start(duration: .zero) }
        #expect(throws: CaptureError.invalidDuration) { try fixture.controller.start(duration: .seconds(-1)) }
        #expect(!fixture.controller.isRecording)
        #expect(fixture.fileSystem.nodes.isEmpty)
    }

    @Test func startsOnceAndStopsByItself() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: CaptureLimits.maximumDuration)
        #expect(fixture.controller.isRecording)
        #expect(info.endsAt == info.startedAt.addingTimeInterval(180))
        #expect(throws: CaptureError.alreadyRecording) { try fixture.controller.start(duration: .seconds(10)) }
        #expect(fixture.controller.remaining(now: info.startedAt.addingTimeInterval(30)) == .seconds(150))
        fixture.advance(seconds: 179)
        #expect(fixture.controller.isRecording)
        fixture.advance(seconds: 1)
        #expect(!fixture.controller.isRecording)
        #expect(fixture.controller.remaining(now: info.endsAt) == nil)
        #expect(fixture.scheduler.pendingCount == 0)
        #expect(fixture.lines(info).last?.type == .end)
        #expect(fixture.lines(info).last?.reason == "timeLimit")
        #expect(fixture.controller.stop() == nil)
    }

    @Test func filesAreOwnerOnlyAndExcludedFromBackup() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        let file = try #require(fixture.fileSystem.nodes[info.file.path])
        let directory = try #require(fixture.fileSystem.nodes[CaptureFixture.directory.path])
        #expect(file.permissions == .ownerOnlyFile)
        #expect(file.excludedFromBackup)
        #expect(directory.permissions == .ownerOnlyDirectory)
        #expect(directory.excludedFromBackup)
        #expect(info.file.deletingLastPathComponent().path == CaptureFixture.directory.path)
        #expect(CaptureFiles.isValid(info.id))
        #expect(info.id.rawValue.hasPrefix("trace-20270115-080000-"))
    }

    @Test func drainsRecordsPeriodicallyInTimeOrder() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.clock.advance(byMicroseconds: 1_000)
        _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0, flags: 1 << 17))
        fixture.clock.advance(byMicroseconds: 500)
        _ = fixture.controller.tapRecords.push(.engine(deleteCount: 1, insert: "á", at: fixture.clock.now()))
        _ = fixture.controller.injectRecords.push(
            .job(sequence: 7, strategy: .backspaceReplace, durationMicroseconds: 850, outcome: "delivered"))
        _ = fixture.controller.focusRecords.push(
            .focus(
                bundle: DiagnosticsFixtures.reportedBundle, role: "AXTextField", subrole: nil,
                at: MonotonicInstant(nanoseconds: fixture.clock.now().nanoseconds - 1_200_000)))
        fixture.advance(seconds: 2)
        let lines = fixture.lines(info)
        #expect(lines.map(\.type) == [.session, .focus, .key, .engine, .job])
        #expect(lines[2].char == "a")
        #expect(lines[2].t == 1_000)
        #expect(lines[3].insert == "á")
        #expect(lines[4].sequence == 7)
        #expect(lines[1].bundle == "com.example.Browser")
    }

    @Test func secureInputGapRecordsNothingAndIsMarked() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.clock.advance(byMicroseconds: 1_000_000)
        fixture.controller.beginGap(.secureInput)
        #expect(!fixture.controller.isRecording)
        fixture.controller.beginGap(.secureField)  // already in a gap: ignored
        fixture.clock.advance(byMicroseconds: 1_000_000)
        // A producer that read the flag just before the gap began: dropped by its timestamp.
        _ = fixture.controller.tapRecords.push(fixture.key("p"))
        fixture.clock.advance(byMicroseconds: 1_000_000)
        fixture.controller.endGap()
        #expect(fixture.controller.isRecording)
        fixture.controller.endGap()  // no open gap: ignored
        fixture.clock.advance(byMicroseconds: 10)
        _ = fixture.controller.tapRecords.push(fixture.key("b"))
        _ = fixture.controller.stop()
        let lines = fixture.lines(info)
        #expect(lines.map(\.type) == [.session, .gap, .key, .end])
        #expect(lines[1].reason == "secureInput")
        #expect(lines[1].t == 1_000_000)
        #expect(lines[1].to == 3_000_000)
        #expect(lines[2].char == "b")
        #expect(!lines.contains { $0.char == "p" })
    }

    @Test func stopClosesAnOpenGap() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.controller.beginGap(.secureField)
        fixture.clock.advance(byMicroseconds: 5_000)
        _ = fixture.controller.tapRecords.push(fixture.key("x"))
        let stopped = fixture.controller.stop()
        #expect(stopped == info)
        let lines = fixture.lines(info)
        #expect(lines.map(\.type) == [.session, .gap, .end])
        #expect(lines[1].to == 5_000)
        fixture.controller.beginGap(.secureInput)  // no session: ignored
        #expect(!fixture.controller.isRecording)
    }

    @Test func recordsLeftFromAnEarlierSessionAreDiscarded() throws {
        let fixture = CaptureFixture.make()
        _ = fixture.controller.tapRecords.push(fixture.key("z"))
        fixture.clock.advance(byMicroseconds: 10)
        let info = try fixture.controller.start(duration: .seconds(5))
        _ = fixture.controller.stop()
        #expect(!fixture.lines(info).contains { $0.type == .key })
    }

    @Test func exportWritesTheTraceThenDeletesIt() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        _ = fixture.controller.tapRecords.push(fixture.key("đ"))
        let destination = URL(fileURLWithPath: "/exports/trace.jsonl")
        try fixture.controller.export(info.id, to: destination)
        #expect(!fixture.controller.isRecording)
        #expect(fixture.fileSystem.nodes[info.file.path] == nil)
        let exported = try #require(fixture.fileSystem.nodes[destination.path])
        #expect(exported.permissions == .ownerOnlyFile)
        #expect(CaptureFiles.decode(exported.data ?? Data()).contains { $0.char == "đ" })
        #expect(throws: CaptureError.unknownSession) { try fixture.controller.export(info.id, to: destination) }
    }

    @Test func discardDeletesImmediately() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.controller.discard(info.id)
        #expect(!fixture.controller.isRecording)
        #expect(fixture.fileSystem.nodes[info.file.path] == nil)
        fixture.controller.discard(info.id)  // already gone: no effect
        fixture.controller.discard(CaptureSessionID(rawValue: "../settings"))
    }

    @Test func purgeDeletesCapturesOlderThanTwentyFourHours() throws {
        let fixture = CaptureFixture.make()
        let old = try fixture.controller.start(duration: .seconds(10))
        _ = fixture.controller.stop()
        fixture.advance(seconds: 12 * 3_600)
        let recent = try fixture.controller.start(duration: .seconds(10))
        _ = fixture.controller.stop()
        let unrelated = CaptureFixture.directory.appendingPathComponent("notes.txt")
        try fixture.fileSystem.writeAtomically(Data(), to: unrelated, permissions: .ownerOnlyFile)
        fixture.controller.purgeExpired(now: old.startedAt.addingTimeInterval(CaptureLimits.retention - 1))
        #expect(fixture.fileSystem.nodes[old.file.path] != nil)
        fixture.controller.purgeExpired(now: old.startedAt.addingTimeInterval(CaptureLimits.retention))
        #expect(fixture.fileSystem.nodes[old.file.path] == nil)
        #expect(fixture.fileSystem.nodes[recent.file.path] != nil)
        #expect(fixture.fileSystem.nodes[unrelated.path] != nil)
        fixture.controller.purgeExpired(now: recent.startedAt.addingTimeInterval(CaptureLimits.retention))
        #expect(fixture.fileSystem.nodes[recent.file.path] == nil)
    }

    @Test func purgeNeverDeletesTheRunningSessionAndToleratesAMissingFolder() throws {
        let fixture = CaptureFixture.make()
        fixture.controller.purgeExpired(now: .distantFuture)
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.controller.purgeExpired(now: .distantFuture)
        #expect(fixture.fileSystem.nodes[info.file.path] != nil)
    }

    @Test func renderShowsWhatWasRecordedInBothLanguages() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.clock.advance(byMicroseconds: 1_234_000)
        _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0x0C, flags: (1 << 17) | (1 << 20)))
        _ = fixture.controller.tapRecords.push(.engine(deleteCount: 1, insert: "ấ\n", at: fixture.clock.now()))
        let english = try fixture.controller.render(info.id, language: .english)
        #expect(english.contains("Typing trace " + info.id.rawValue))
        #expect(english.contains("+1.234 s  keyDown  0x0c  shift+cmd  \"a\"  passed"))
        #expect(english.contains("engine  delete 1  insert \"ấU+000A\""))
        _ = fixture.controller.stop()
        let vietnamese = try fixture.controller.render(info.id, language: .vietnamese)
        #expect(vietnamese.contains("Bản ghi thao tác gõ"))
        #expect(vietnamese.contains("kết thúc (stopped)"))
        #expect(throws: CaptureError.unknownSession) {
            try fixture.controller.render(CaptureSessionID(rawValue: "trace-missing"), language: .english)
        }
        #expect(throws: CaptureError.unknownSession) {
            try fixture.controller.render(CaptureSessionID(rawValue: "../../etc/x"), language: .english)
        }
    }

    @Test func storageFailureSurfacesAsCaptureError() throws {
        let memory = InMemoryFileSystem()
        let controller = CaptureController(
            directory: CaptureFixture.directory, fileSystem: FailingAppendFileSystem(base: memory, failures: 1),
            wallClock: FixedWallClock(), clock: ManualClock(), scheduler: ManualScheduler(clock: ManualClock()))
        let error = #expect(throws: CaptureError.self) { try controller.start(duration: .seconds(5)) }
        guard case .storage(.ioFailure(_, let code)) = error else {
            Issue.record("expected a storage error, got \(String(describing: error))")
            return
        }
        #expect(code == 28)
        #expect(!controller.isRecording)
        _ = try controller.start(duration: .seconds(5))
        #expect(controller.isRecording)
    }

    /// Real files through `LocalFileSystem`: 0700 folder, 0600 file, `isExcludedFromBackup` set.
    @Test func localFilesAreOwnerOnlyAndExcludedFromBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w1a-captures-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("captures")
        let clock = ManualClock()
        let controller = CaptureController(
            directory: directory, fileSystem: LocalFileSystem(), wallClock: SystemWallClock(), clock: clock,
            scheduler: ManualScheduler(clock: clock))
        let info = try controller.start(duration: .seconds(60))
        _ = controller.stop()
        let fileSystem = LocalFileSystem()
        #expect(try fileSystem.attributes(at: directory).permissions == .ownerOnlyDirectory)
        #expect(try fileSystem.attributes(at: info.file).permissions == .ownerOnlyFile)
        #expect(try info.file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try controller.export(info.id, to: root.appendingPathComponent("export.jsonl"))
        #expect(!fileSystem.fileExists(at: info.file))
        #expect(
            try fileSystem.attributes(at: root.appendingPathComponent("export.jsonl")).permissions == .ownerOnlyFile)
    }

    @Test func renderCoversEveryLineKind() throws {
        let fixture = CaptureFixture.make()
        let info = try fixture.controller.start(duration: .seconds(60))
        fixture.clock.advance(byMicroseconds: 2_000)
        _ = fixture.controller.focusRecords.push(
            .focus(
                bundle: DiagnosticsFixtures.reportedBundle, role: "AXTextArea", subrole: nil, at: fixture.clock.now()))
        _ = fixture.controller.injectRecords.push(
            .job(sequence: 3, strategy: .paste, durationMicroseconds: 1_200, outcome: "delivered"))
        _ = fixture.controller.tapRecords.push(
            .key(
                KeyCaptureRecord(
                    kind: .flagsChanged, keyCode: 0x38, flags: 1 << 17, character: .empty, outcome: .passed,
                    at: fixture.clock.now())))
        fixture.clock.advance(byMicroseconds: 1)  // records at the gap boundary itself are dropped
        fixture.controller.beginGap(.secureField)
        fixture.clock.advance(byMicroseconds: 1_500_000)
        fixture.controller.endGap()
        fixture.clock.advance(byMicroseconds: 1)
        _ = fixture.controller.tapRecords.push(
            .gap(reason: .secureInput, from: fixture.clock.now(), to: fixture.clock.now()))
        fixture.advance(seconds: 60)
        for language in InterfaceLanguage.allCases {
            let text = try fixture.controller.render(info.id, language: language)
            #expect(text.split(separator: "\n").count == 8)
        }
        let english = try fixture.controller.render(info.id, language: .english)
        #expect(english.contains("+0.002 s  focus  com.example.Browser  AXTextArea  -"))
        #expect(english.contains("job 3  paste  1200 µs  delivered"))
        #expect(english.contains("+0.002 s  flagsChanged  0x38  shift  -  passed"))
        #expect(english.contains("+0.002 s  gap until +1.502 s (secureField): nothing recorded"))
        #expect(english.contains("+1.502 s  gap until +1.502 s (secureInput): nothing recorded"))
        #expect(english.contains("end (timeLimit)"))
        let vietnamese = try fixture.controller.render(info.id, language: .vietnamese)
        #expect(vietnamese.contains("lệnh chèn 3"))
        #expect(vietnamese.contains("ô nhập  com.example.Browser"))
        #expect(vietnamese.contains("khoảng trống đến +1.502 s (secureField): không ghi lại gì"))
    }

    @Test func renderingHelpersFormatTimeKeysAndModifiers() {
        #expect(CaptureRendering.seconds(0) == "+0.000 s")
        #expect(CaptureRendering.seconds(61_005_999) == "+61.005 s")
        #expect(CaptureRendering.hex(0x7B) == "0x7b")
        #expect(CaptureRendering.modifiers(0) == "-")
        #expect(CaptureRendering.modifiers((1 << 16) | (1 << 18) | (1 << 19) | (1 << 23)) == "caps+ctrl+opt+fn")
        #expect(CaptureRendering.visible("a\u{200B}\r") == "aU+200BU+000D")
    }
}
