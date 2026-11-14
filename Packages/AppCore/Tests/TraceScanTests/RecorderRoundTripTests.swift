// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): what the dev recorder writes is what the scanner reads. The recorder (Diagnostics) writes
// into an in-memory file system; the files are copied to a temporary folder and scanned, so a field renamed on
// one side fails here.

#if DEV_RECORDER
import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import Diagnostics
@testable import TestSupport
@testable import TraceScanCore

/// Wall time that follows the manual monotonic clock.
private final class FollowingWallClock: WallClock, Sendable {
    private let clock: ManualClock
    private let origin: MonotonicInstant
    private let base: Date
    init(clock: ManualClock, base: Date) {
        self.clock = clock
        self.base = base
        origin = clock.now()
    }
    func now() -> Date { base.addingTimeInterval(clock.now().duration(since: origin).inSeconds) }
}

@Suite struct RecorderRoundTripTests {
    @Test func theScannerReadsWhatTheRecorderWrites() throws {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let base = Date(timeIntervalSince1970: Double(TraceBuilder.base) / 1_000_000)
        let fileSystem = InMemoryFileSystem()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true), fileSystem: fileSystem,
            wallClock: FollowingWallClock(clock: clock, base: base), clock: clock, scheduler: scheduler)
        let dev = capture.dev
        try dev.start(appVersion: "0.1.0 (1)")
        dev.noteSettings(DevSettingsSnapshot(values: TraceBuilder.settings))
        dev.pushFocus(
            .focus(
                DevFocusRecord(
                    generation: 2, bundle: TraceBuilder.editor, role: "AXTextArea", subrole: nil, rule: "editor.sample",
                    strategy: "backspaceReplace", requireTextFocus: "whenKnown", axAvailability: "available",
                    secure: false, mode: "vietnamese", modeSource: "globalMode", engineContext: "general",
                    englishRestore: true, macros: true, pause: nil, at: clock.now())))
        func key(_ character: String, outcome: KeyCaptureRecord.Outcome) {
            _ = capture.tapRecords.push(
                .key(
                    KeyCaptureRecord(
                        kind: .keyDown, keyCode: 0, flags: 0, character: InlineUTF16(character) ?? .empty,
                        outcome: outcome, at: clock.now())))
        }
        scheduler.advance(by: .milliseconds(100))
        key("a", outcome: .passed)
        dev.pushTap(
            .engine(
                DevEngineStep(
                    action: .passThrough, deleteCount: 0, insert: "", composing: "a", decision: nil, at: clock.now())))
        scheduler.advance(by: .milliseconds(120))
        key("a", outcome: .consumedForEdit)
        dev.pushTap(
            .engine(
                DevEngineStep(
                    action: .edit, deleteCount: 1, insert: "â", composing: "â", decision: nil, at: clock.now())))
        scheduler.advance(by: .milliseconds(120))
        dev.pushTap(.boundary(reason: SampleReason.focusChanged, job: SampleReason.focusChanged, at: clock.now()))
        dev.mark(source: .menu)
        dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 9, generation: 2, kind: SampleReason.compose, strategy: .backspaceReplace,
                    outcome: "executed", deleteCount: 1, insertCount: 1, eventsPosted: 4, totalMicroseconds: 90_000,
                    runMicroseconds: 1_000, at: clock.now())))
        dev.note(
            .readback(
                DevReadbackRecord(
                    reason: .marker, status: .ok, textBeforeCaret: "â", selectionLocation: 1, selectionLength: 0,
                    bundle: TraceBuilder.editor, rule: "editor.sample", at: clock.now())))
        scheduler.advance(by: .seconds(2))

        let folder = TraceBuilder.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (path, node) in fileSystem.nodes where path.hasSuffix(".jsonl") {
            try (node.data ?? Data()).write(
                to: folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
        }
        let result = TraceScanCommand.run(
            ["summary", "--dir", folder.path], now: base, timeZone: .current, makeReplay: { nil })
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Launches: 1"))
        #expect(result.output.contains("Apps (key downs): com.example.editor 2"))
        #expect(result.output.contains("Key downs: 2, engine steps: 2, jobs: 1, readbacks: 1, markers: 1"))
        #expect(result.output.contains("Unreadable lines: 0"))
        #expect(result.output.contains("resetWithOpenToken  focusChanged / focusChanged, token of 1 characters open"))
        #expect(result.output.contains("marker  menu"))
        #expect(result.output.contains("injectionProblem  job 9 compose backspaceReplace: slow 90 ms"))
        let shown = TraceScanCommand.run(
            ["show", "1", "--dir", folder.path, "--before", "1s"], now: base, timeZone: .current, makeReplay: { nil })
        #expect(shown.output.contains("engine  edit  delete 1  insert \"â\"  token \"â\""))
        #expect(shown.output.contains("focus  com.example.editor  AXTextArea  -  rule editor.sample"))
    }
}

/// Stand-ins for the engine and injection enums the recorder boxes (their names are what the file holds).
private enum SampleReason: Sendable {
    case focusChanged, compose
}
#endif
