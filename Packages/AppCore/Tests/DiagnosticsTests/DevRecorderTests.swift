// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007), the dev builds' continuous typing recorder: always on once started, hourly 0600 files
// excluded from backup in a 0700 folder, secure gaps and pauses record nothing, ring overflow becomes a gap line,
// retention of 7 days and 200 MB, and the PLT-R905 capture keeps working beside it.

#if DEV_RECORDER
import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import Diagnostics
@testable import TestSupport

/// Wall clock that moves with the manual monotonic clock, so drains see both clocks agree as on a real Mac.
final class LinkedWallClock: WallClock, Sendable {
    private let origin: MonotonicInstant
    private let base: Date
    private let clock: ManualClock
    init(base: Date, clock: ManualClock) {
        self.base = base
        self.clock = clock
        origin = clock.now()
    }
    func now() -> Date { base.addingTimeInterval(clock.now().duration(since: origin).inSeconds) }
}

enum SampleDecision: Sendable { case kept(SampleRule) }
enum SampleRule: Sendable { case notEnglish }

struct DevRecorderFixture {
    static let captures = URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true)
    static let traces = URL(fileURLWithPath: "/logs/SampleApp/dev-traces", isDirectory: true)
    let wallClock: LinkedWallClock
    let clock: ManualClock
    let scheduler: ManualScheduler
    let fileSystem: InMemoryFileSystem
    let controller: CaptureController
    var dev: DevRecorder { controller.dev }

    static func make(at date: Date = DiagnosticsFixtures.generatedAt) -> DevRecorderFixture {
        let clock = ManualClock()
        let wallClock = LinkedWallClock(base: date, clock: clock)
        let scheduler = ManualScheduler(clock: clock)
        let fileSystem = InMemoryFileSystem(now: { wallClock.now() })
        let controller = CaptureController(
            directory: captures, fileSystem: fileSystem, wallClock: wallClock, clock: clock, scheduler: scheduler)
        return DevRecorderFixture(
            wallClock: wallClock, clock: clock, scheduler: scheduler, fileSystem: fileSystem, controller: controller)
    }

    func advance(milliseconds: Int) { scheduler.advance(by: .milliseconds(milliseconds)) }

    func advance(seconds: Int) { advance(milliseconds: seconds * 1_000) }

    func key(_ character: String, keyCode: UInt16 = 0, outcome: KeyCaptureRecord.Outcome = .passed) -> CaptureRecord {
        .key(
            KeyCaptureRecord(
                kind: .keyDown, keyCode: keyCode, flags: 0, character: InlineUTF16(character) ?? .empty,
                outcome: outcome, at: clock.now()))
    }

    func engine(insert: String, delete: Int = 0, composing: String) -> DevTraceRecord {
        .engine(
            DevEngineStep(
                action: .edit, deleteCount: delete, insert: insert, composing: composing, decision: nil,
                at: clock.now()))
    }

    static func focus(role: String, at instant: MonotonicInstant) -> DevFocusRecord {
        DevFocusRecord(
            generation: 4, bundle: "com.example.editor", role: role, subrole: nil, rule: "editor.sample",
            strategy: "backspaceReplace", requireTextFocus: "whenKnown", axAvailability: "available", secure: false,
            mode: "vietnamese", modeSource: "global", engineContext: "general", englishRestore: true, macros: true,
            pause: nil, at: instant)
    }

    var hour: String { DevTraceFiles.hourKey(for: wallClock.now(), timeZone: .current) }

    func file(_ hour: String) -> URL { DevTraceFiles.url(forHour: hour, in: Self.traces) }

    func lines(_ hour: String) -> [DevTraceLine] {
        let data = fileSystem.nodes[file(hour).path]?.data ?? Data()
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(DevTraceLine.self, from: Data($0)) }
    }

    func types(_ hour: String) -> [DevTraceLine.Kind] { lines(hour).map(\.type) }
}

@Suite struct DevRecorderTests {
    @Test func recordsNothingUntilStarted() {
        let fixture = DevRecorderFixture.make()
        #expect(!fixture.dev.isActive)
        #expect(!fixture.controller.isRecording)
        fixture.dev.pushTap(fixture.engine(insert: "a", composing: "a"))
        fixture.advance(seconds: 3)
        #expect(fixture.fileSystem.nodes.isEmpty)
    }

    /// PLT-R904A: always on from launch, no confirmation; folder 0700 and files 0600, both excluded from backup.
    @Test func startsAtOnceWithOwnerOnlyFilesExcludedFromBackup() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "0.1.0 (7)")
        #expect(fixture.dev.isActive)
        #expect(fixture.controller.isRecording)
        fixture.advance(seconds: 2)
        let folder = try #require(fixture.fileSystem.nodes[DevRecorderFixture.traces.path])
        #expect(folder.permissions == .ownerOnlyDirectory && folder.excludedFromBackup)
        let file = try #require(fixture.fileSystem.nodes[fixture.file(fixture.hour).path])
        #expect(file.permissions == .ownerOnlyFile && file.excludedFromBackup)
        let lines = fixture.lines(fixture.hour)
        #expect(lines.map(\.type) == [.file, .start])
        #expect(lines[0].build == DevRecorder.buildMarker && lines[0].v == 2 && lines[0].app == "0.1.0 (7)")
        #expect(lines[1].launch == lines[0].launch)
        #expect(fixture.scheduler.repeatingIntervals.min() == .seconds(2))
    }

    /// Keys from the shared PLT-R905 ring and engine steps from the dev ring, in time order, with wall-clock times.
    @Test func keysAndEngineStepsAreWrittenInOrderWithWallClockTimes() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        let startMicros = DevTraceFiles.microseconds(fixture.wallClock.now())
        fixture.advance(milliseconds: 100)
        _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0))
        fixture.dev.pushTap(fixture.engine(insert: "a", composing: "a"))
        fixture.advance(milliseconds: 120)
        _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0, outcome: .consumedForEdit))
        fixture.dev.pushTap(fixture.engine(insert: "â", delete: 1, composing: "â"))
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour).filter { $0.type == .key || $0.type == .engine }
        #expect(lines.map(\.type) == [.key, .engine, .key, .engine])
        #expect(lines.map(\.t) == [100_000, 100_000, 220_000, 220_000].map { startMicros + $0 })
        #expect(lines[2].out == "consumedForEdit" && lines[2].ch == "a" && lines[2].kc == 0)
        #expect(lines[3].ins == "â" && lines[3].del == 1 && lines[3].comp == "â" && lines[3].act == "edit")
    }

    /// Review W8-E finding 2: a key the tap pushes while a drain runs (after the dev rings were popped) is written
    /// with the next drain, and its engine step, pushed after it, never ends up in a file before it.
    @Test func aKeyRacingTheDrainIsNeverWrittenAfterItsEngineStep() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.advance(milliseconds: 100)
        fixture.controller.drainNow(betweenRings: {
            _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0))
            fixture.dev.pushTap(fixture.engine(insert: "a", composing: "a"))
        })
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour).filter { $0.type == .key || $0.type == .engine }
        #expect(lines.map(\.type) == [.key, .engine])
    }

    /// Within one drain the key line leads the dev records of the same instant, whichever ring was popped first.
    @Test func theKeyLineLeadsTheDevRecordsOfItsInstant() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.advance(milliseconds: 100)
        fixture.dev.pushTap(fixture.engine(insert: "a", composing: "a"))
        fixture.dev.pushTap(.boundary(reason: SampleDecision.kept(.notEnglish), job: nil, at: fixture.clock.now()))
        _ = fixture.controller.tapRecords.push(fixture.key("a", keyCode: 0))
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour).filter { [.key, .engine, .boundary].contains($0.type) }
        #expect(lines.map(\.type) == [.key, .engine, .boundary])
    }

    /// One file per local hour; each new file starts with its header, the settings and the focus in effect.
    @Test func rotatesEveryHourWithAHeaderPerFile() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.noteSettings(DevSettingsSnapshot(values: ["inputMethod": "telex"]))
        fixture.dev.pushFocus(
            .focus(
                DevFocusRecord(
                    generation: 3, bundle: "com.example.editor", role: "AXTextArea", subrole: nil,
                    rule: "editor.sample", strategy: "backspaceReplace", requireTextFocus: "whenKnown",
                    axAvailability: "available", secure: false, mode: "vietnamese", modeSource: "global",
                    engineContext: "general", englishRestore: true, macros: true, pause: nil, at: fixture.clock.now())))
        fixture.advance(seconds: 2)
        let first = fixture.hour
        fixture.advance(seconds: 3_600)
        _ = fixture.controller.tapRecords.push(fixture.key("b", keyCode: 11))
        fixture.advance(seconds: 2)
        let second = fixture.hour
        #expect(first != second)
        #expect(fixture.types(first) == [.file, .start, .settings, .focus])
        #expect(fixture.types(second) == [.file, .settings, .focus, .key])
        #expect(fixture.lines(second)[1].s == ["inputMethod": "telex"])
        #expect(fixture.lines(second)[2].rule == "editor.sample")
    }

    /// PLT-R905 rule kept: nothing while secure input is on or a secure field is focused; the gap is marked.
    @Test func secureGapsRecordNothingAndAreMarked() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.advance(milliseconds: 100)
        fixture.controller.beginGap(.secureField)
        #expect(!fixture.dev.isActive && !fixture.controller.isRecording)
        // A record a producer queued after the gap began (it read the flag just before) is dropped too.
        _ = fixture.controller.tapRecords.push(fixture.key("p"))
        fixture.advance(milliseconds: 500)
        fixture.controller.endGap()
        #expect(fixture.dev.isActive)
        fixture.advance(milliseconds: 100)
        _ = fixture.controller.tapRecords.push(fixture.key("x", keyCode: 7))
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour)
        #expect(lines.map(\.type) == [.file, .start, .gap, .key])
        #expect(lines[2].reason == "secureField" && lines[2].end.map { $0 - lines[2].t } == 500_000)
        #expect(lines[3].ch == "x")
    }

    /// Review W8-E finding 3: focus changes inside a gap are not recorded, so the focus in effect when it ends is.
    @Test func theFocusInEffectIsWrittenWhenASecureGapEnds() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.setFocusSource { at in DevRecorderFixture.focus(role: "AXTextArea", at: at) }
        fixture.advance(milliseconds: 100)
        fixture.controller.beginGap(.secureField)
        fixture.advance(milliseconds: 500)
        fixture.controller.endGap()
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour)
        #expect(lines.map(\.type) == [.file, .start, .gap, .focus])
        #expect(lines[3].role == "AXTextArea" && lines[3].t == lines[2].end)
    }

    /// The same at the end of a pause; a gap that ends inside the pause writes nothing until the resume.
    @Test func theFocusInEffectIsWrittenWhenAPauseEnds() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.setFocusSource { at in DevRecorderFixture.focus(role: "AXTextField", at: at) }
        fixture.dev.pause()
        fixture.controller.beginGap(.secureField)
        fixture.advance(seconds: 5)
        fixture.controller.endGap()
        fixture.advance(seconds: 5)
        fixture.dev.resume()
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour)
        #expect(lines.map(\.type).filter { $0 != .gap } == [.file, .start, .pause, .resume, .focus])
        #expect(lines.last?.role == "AXTextField")
    }

    /// "Tạm dừng ghi 30 phút": nothing is recorded, then it resumes by itself.
    @Test func pauseRecordsNothingAndResumesAfterThirtyMinutes() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.pause()
        #expect(!fixture.dev.isActive)
        let until = try #require(fixture.dev.pausedUntil)
        #expect(until == fixture.wallClock.now().addingTimeInterval(1_800))
        fixture.dev.note(.marker(source: .menu, at: fixture.clock.now()))
        fixture.advance(seconds: 1_799)
        #expect(!fixture.dev.isActive)
        fixture.advance(seconds: 1)
        #expect(fixture.dev.isActive && fixture.dev.pausedUntil == nil)
        let firstHour = DevTraceFiles.hourKey(for: until.addingTimeInterval(-1_800), timeZone: .current)
        let hours = firstHour == fixture.hour ? [firstHour] : [firstHour, fixture.hour]
        let all = hours.flatMap { fixture.lines($0) }
        let types = all.map(\.type).filter { $0 != .file }
        #expect(types == [.start, .pause, .resume])
        #expect(all.first { $0.type == .pause }?.until == DevTraceFiles.microseconds(until))
    }

    @Test func resumeEndsAPauseEarly() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.pause()
        fixture.advance(seconds: 10)
        fixture.dev.resume()
        #expect(fixture.dev.isActive)
        fixture.dev.mark(source: .menu)
        fixture.advance(seconds: 2)
        #expect(fixture.types(fixture.hour) == [.file, .start, .pause, .resume, .marker])
        #expect(fixture.lines(fixture.hour).last?.src == "menu")
    }

    /// A full ring is never silent: the next drain writes a gap line with the number of records lost.
    @Test func ringOverflowWritesAGapLine() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        var index = 0
        while index < fixture.dev.focusRecords.capacity + 3 {
            fixture.dev.pushFocus(.marker(source: .chord, at: fixture.clock.now()))
            index += 1
        }
        fixture.advance(seconds: 2)
        let gap = try #require(fixture.lines(fixture.hour).first { $0.type == .gap })
        #expect(gap.reason == "overflow" && gap.dropped == 3)
    }

    /// The marker chord and readbacks reach the attention queue without locks; the menu marker writes a line.
    @Test func attentionRequestsAccumulateUntilTaken() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        fixture.dev.requestAttention(.backspaceEdit)
        fixture.dev.requestAttention(.marker)
        #expect(fixture.dev.takeAttention() == [.backspaceEdit, .marker])
        #expect(fixture.dev.takeAttention().isEmpty)
    }

    /// PLT-R904A readback pause: the tap reports every key or click down, the inject thread every finished job.
    @Test func inputAndJobsAreTrackedForTheReadbackPause() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        #expect(fixture.dev.inputActivity == DevInputActivity(count: 0, lastInput: nil, lastJob: nil))
        fixture.advance(milliseconds: 40)
        fixture.dev.noteInputDown(at: fixture.clock.now())
        let keyAt = fixture.clock.now()
        fixture.advance(milliseconds: 15)
        fixture.dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 1, generation: 1, kind: SampleRule.notEnglish, strategy: .backspaceReplace,
                    outcome: "executed", deleteCount: 1, insertCount: 1, eventsPosted: 4, totalMicroseconds: 15_000,
                    runMicroseconds: 2_000, at: fixture.clock.now())))
        let activity = fixture.dev.inputActivity
        #expect(activity == DevInputActivity(count: 1, lastInput: keyAt, lastJob: fixture.clock.now()))
        #expect(activity.latest == fixture.clock.now())
    }

    /// The readback line carries the AX read's duration, the wait since the trigger, the input's idle time and the
    /// overlap flag (written only when a key went down during the read).
    @Test func readbackLinesCarryTheirTiming() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        var record = DevReadbackRecord(
            reason: .commit, status: .ok, textBeforeCaret: "máy co", selectionLocation: 6, selectionLength: 0,
            bundle: "com.example.editor", rule: nil, at: fixture.clock.now())
        record.durationMicroseconds = 12_300
        record.waitMicroseconds = 1_250_000
        record.idleMicroseconds = 1_000_000
        record.overlap = true
        fixture.dev.note(.readback(record))
        record.overlap = false
        record.durationMicroseconds = nil
        fixture.dev.note(.readback(record))
        fixture.advance(seconds: 2)
        let lines = fixture.lines(fixture.hour).filter { $0.type == .readback }
        #expect(lines.count == 2)
        #expect(lines[0].durUs == 12_300 && lines[0].waitUs == 1_250_000 && lines[0].idleUs == 1_000_000)
        #expect(lines[0].overlap == true)
        #expect(lines[1].overlap == nil && lines[1].durUs == nil)
    }

    /// PLT-R904A retention: 7 days, then 200 MB (a small cap here) oldest first; the file in use and foreign files
    /// stay.
    @Test func purgeKeepsSevenDaysAndTwoHundredMegabytes() throws {
        let fixture = DevRecorderFixture.make()
        let now = fixture.wallClock.now()
        func name(hoursAgo: Int) -> URL {
            fixture.file(
                DevTraceFiles.hourKey(for: now.addingTimeInterval(TimeInterval(-hoursAgo * 3_600)), timeZone: .current))
        }
        try fixture.fileSystem.createDirectory(at: DevRecorderFixture.traces, permissions: .ownerOnlyDirectory)
        let old = name(hoursAgo: 7 * 24 + 2)
        let big = name(hoursAgo: 30)
        let recent = name(hoursAgo: 2)
        let foreign = DevRecorderFixture.traces.appendingPathComponent("notes.txt")
        try fixture.fileSystem.append(Data("x".utf8), to: old, permissions: .ownerOnlyFile)
        try fixture.fileSystem.append(Data(count: 30), to: big, permissions: .ownerOnlyFile)
        try fixture.fileSystem.append(Data(count: 10), to: recent, permissions: .ownerOnlyFile)
        try fixture.fileSystem.append(Data("y".utf8), to: foreign, permissions: .ownerOnlyFile)
        try fixture.dev.start(appVersion: "1")  // purges at launch
        #expect(!fixture.fileSystem.fileExists(at: old))
        #expect(fixture.fileSystem.fileExists(at: big))
        #expect(fixture.fileSystem.fileExists(at: recent))
        #expect(fixture.fileSystem.fileExists(at: foreign))
        // Over the size cap the oldest goes first; the file in use is never deleted.
        fixture.advance(seconds: 2)
        let current = fixture.file(fixture.hour)
        let currentSize = try fixture.fileSystem.attributes(at: current).size
        fixture.dev.purge(now: fixture.wallClock.now(), maximumBytes: currentSize + 15)
        #expect(!fixture.fileSystem.fileExists(at: big))
        #expect(fixture.fileSystem.fileExists(at: recent))
        fixture.dev.purge(now: fixture.wallClock.now(), maximumBytes: 0)
        #expect(!fixture.fileSystem.fileExists(at: recent))
        #expect(fixture.fileSystem.fileExists(at: current))
        #expect(fixture.fileSystem.fileExists(at: foreign))
        // The hourly timer runs the same purge.
        #expect(fixture.scheduler.repeatingIntervals.contains(DevRecorderLimits.purgeInterval))
    }

    @Test func fileNamesRoundTrip() {
        let date = DiagnosticsFixtures.generatedAt
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        #expect(DevTraceFiles.hourKey(for: date, timeZone: utc) == "20270115-08")
        #expect(DevTraceFiles.hourStart(ofFileNamed: "20270115-08.jsonl", timeZone: utc) == date)
        #expect(DevTraceFiles.hourStart(ofFileNamed: "20270115-8.jsonl", timeZone: utc) == nil)
        #expect(DevTraceFiles.hourStart(ofFileNamed: "20271315-08.jsonl", timeZone: utc) == nil)
        #expect(DevTraceFiles.hourStart(ofFileNamed: "trace-x.jsonl", timeZone: utc) == nil)
    }

    /// PLT-R905 unchanged in dev builds: a time-boxed capture records its own file while the recorder runs.
    @Test func theTimeBoxedCaptureStillWorksBesideTheRecorder() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        _ = fixture.controller.tapRecords.push(fixture.key("q"))
        let info = try fixture.controller.start(duration: .seconds(10))
        fixture.advance(milliseconds: 10)
        _ = fixture.controller.tapRecords.push(fixture.key("w", keyCode: 13))
        fixture.advance(seconds: 10)
        let capture = CaptureFiles.decode(fixture.fileSystem.nodes[info.file.path]?.data ?? Data())
        #expect(capture.map(\.type) == [.session, .key, .end])
        #expect(capture[1].char == "w")
        #expect(fixture.lines(fixture.hour).filter { $0.type == .key }.map(\.ch) == ["q", "w"])
    }

    @Test func stopWritesAFinalLineAndEndsRecording() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        _ = fixture.controller.tapRecords.push(fixture.key("z", keyCode: 6))
        fixture.dev.stop()
        #expect(!fixture.dev.isActive && !fixture.dev.isStarted)
        #expect(fixture.types(fixture.hour) == [.file, .start, .key, .stop])
        #expect(fixture.scheduler.pendingCount == 0)
    }

    /// A week of 2 s drains reads the drain hook 300,000 times; a function value read through a mutex would grow a
    /// thunk chain each time and overflow the stack when released.
    @Test func manyDrainsKeepTheDrainHookFlat() throws {
        do {
            let fixture = DevRecorderFixture.make()
            try fixture.dev.start(appVersion: "1")
            fixture.dev.addAttentionListener { _ in }
            var index = 0
            while index < 20_000 {
                fixture.dev.drain()
                index += 1
            }
        }
        #expect(Bool(true))  // reaching this line means the release did not recurse
    }

    @Test func enumNamesLoseTheirQualifiers() {
        #expect(DevTraceNames.describe(SampleDecision.kept(.notEnglish)) == "kept(notEnglish)")
        #expect(DevTraceNames.describe(SampleRule.notEnglish) == "notEnglish")
    }

    /// The release check looks for this string; Swift keeps strings of 16 bytes or more in the binary's data.
    @Test func buildMarkerIsLongEnoughToSurviveInTheBinary() {
        #expect(DevRecorder.buildMarker.utf8.count > 15)
    }

    /// PLT-R304, PLT-R305: the tap's side of the recorder takes no lock and allocates nothing.
    @Test func tapSideAllocatesNothing() throws {
        let fixture = DevRecorderFixture.make()
        try fixture.dev.start(appVersion: "1")
        let insert = String(repeating: "ư", count: 3)
        let composing = String(repeating: "ơ", count: 9)
        let reason: any Sendable = DevReadbackReason.commit
        let step = DevEngineStep(
            action: .edit, deleteCount: 1, insert: insert, composing: composing, decision: nil, at: .zero)
        let dev = fixture.dev
        var sink = 0
        func tapSide() {
            if dev.isActive { sink &+= 1 }
            dev.pushTap(.engine(step))
            dev.pushTap(.boundary(reason: reason, job: nil, at: .zero))
            dev.requestAttention(.commit)
            dev.noteInputDown(at: .zero)
            _ = dev.tapRecords.pop()
            _ = dev.tapRecords.pop()
        }
        tapSide()  // warms up lazy type metadata
        var index = 0
        let count = AllocationCounter.count {
            while index < 1_000 {
                tapSide()
                index += 1
            }
        }
        if let count { #expect(count == 0) }
        #expect(sink == 1_001)
    }
}
#endif
