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
                    runMicroseconds: 1_000, at: clock.now(), completion: "selected", completionReadMicroseconds: 480)))
        dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 10, generation: 2, kind: SampleReason.compose, strategy: .backspaceReplace,
                    outcome: "executed", deleteCount: 1, insertCount: 1, eventsPosted: 6, totalMicroseconds: 1_600,
                    runMicroseconds: 1_400, at: clock.now(), completion: "forwardDelete",
                    completionReadMicroseconds: 23_400)))
        // PLT-R423 caret continuity (amendment of 16/11/2026): a read that did not answer kept an earlier answer.
        dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 11, generation: 2, kind: SampleReason.compose, strategy: .backspaceReplace,
                    outcome: "executed", deleteCount: 2, insertCount: 2, eventsPosted: 12, totalMicroseconds: 49_800,
                    runMicroseconds: 49_600, at: clock.now(), completion: "forwardDelete kept",
                    completionReadMicroseconds: 48_000, completionKeptJobs: 2, completionKeptAgeMicroseconds: 180_300)))
        // PLT-R357, retest of 16/11/2026: a revision that fell back names its read-back.
        dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 12, generation: 2, kind: SampleReason.revision, strategy: .backspaceReplace,
                    outcome: "executedWithFallback", deleteCount: 6, insertCount: 5, eventsPosted: 0,
                    totalMicroseconds: 1_200, runMicroseconds: 1_100, at: clock.now(),
                    readback: "mismatch differs afterSettle")))
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
        #expect(result.output.contains("Key downs: 2, engine steps: 2, jobs: 4, readbacks: 1, markers: 1"))
        #expect(result.output.contains("Unreadable lines: 0"))
        #expect(result.output.contains("resetWithOpenToken  focusChanged / focusChanged, token of 1 characters open"))
        #expect(result.output.contains("marker  menu"))
        #expect(result.output.contains("injectionProblem  job 9 compose backspaceReplace: slow 90 ms"))
        #expect(!result.output.contains("job 10"))  // PLT-R423: two more events per deletion are not a problem
        #expect(!result.output.contains("job 11"))  // a kept answer sent its Forward Deletes: nothing was lost
        #expect(
            result.output.contains(
                "revisionFellBack  job 12 revision backspaceReplace: outcome executedWithFallback, 0 events, "
                    + "readback mismatch differs afterSettle"))
        let shown = TraceScanCommand.run(
            ["show", "1", "--dir", folder.path, "--before", "1s"], now: base, timeZone: .current, makeReplay: { nil })
        #expect(shown.output.contains("engine  edit  delete 1  insert \"â\"  token \"â\""))
        #expect(shown.output.contains("focus  com.example.editor  AXTextArea  -  rule editor.sample"))
        #expect(shown.output.contains("4 events  completion selected read 480 us"))  // PLT-R420 read (15/11/2026)
        // PLT-R423, with the read's duration since the retest of 16/11/2026.
        #expect(shown.output.contains("6 events  completion forwardDelete read 23.4 ms  1.6 ms total"))
        #expect(
            shown.output.contains(
                "12 events  completion forwardDelete kept read 48.0 ms, from read 2 jobs ago (180.3 ms)  49.8 ms total")
        )
        #expect(shown.output.contains("0 events  readback mismatch differs afterSettle  1.2 ms total"))
    }
}

/// Stand-ins for the engine and injection enums the recorder boxes (their names are what the file holds).
private enum SampleReason: Sendable {
    case focusChanged, compose, revision
}
#endif
