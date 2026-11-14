// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007), the tap's side of the dev recorder: every engine call with the token after it, every hard
// boundary with its reasons (stamped at the event that caused it), the marker chord, readback requests, the
// PLT-R905 secure rules, and no allocation on the tap (PLT-R304, PLT-R305).

#if DEV_RECORDER
import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private let semicolon: UInt16 = 0x29
private let markerFlags = Flag.control | Flag.option | Flag.command

private func startedCapture(clock: ManualClock) throws -> CaptureController {
    let capture = CaptureController(
        directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
        fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
        scheduler: ManualScheduler(clock: clock))
    try capture.dev.start(appVersion: "test")
    return capture
}

private func devRecords(_ capture: CaptureController) -> [DevTraceRecord] {
    var records: [DevTraceRecord] = []
    while let record = capture.dev.tapRecords.pop() { records.append(record) }
    return records
}

private func keyRecords(_ capture: CaptureController) -> [KeyCaptureRecord] {
    var keys: [KeyCaptureRecord] = []
    while let record = capture.tapRecords.pop() {
        if case .key(let key) = record { keys.append(key) }
    }
    return keys
}

private func steps(_ records: [DevTraceRecord]) -> [DevEngineStep] {
    records.compactMap { record in
        if case .engine(let step) = record { return step }
        return nil
    }
}

private func boundaries(_ records: [DevTraceRecord]) -> [(reason: String, job: String?, at: MonotonicInstant)] {
    records.compactMap { record in
        if case .boundary(let reason, let job, let at) = record {
            return (String(describing: reason), job.map { String(describing: $0) }, at)
        }
        return nil
    }
}

@Suite struct DevRecorderPipelineTests {
    /// Every engine call, edits or not, with the token's display after the key.
    @Test func everyEngineCallIsRecordedWithTheTokenAfterIt() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.typeKeys([Key.a, Key.a, Key.space])
        let recorded = steps(devRecords(capture))
        #expect(recorded.map(\.action) == [.passThrough, .edit, .passThrough])
        #expect(recorded.map(\.composing) == ["a", "â", ""])
        #expect(recorded[1].deleteCount == 1 && recorded[1].insert == "â")
        // The shared PLT-R905 key lines still come first, one per physical event.
        #expect(keyRecords(capture).map(\.character.string) == ["a", "a", "a", "a", " ", " "])
    }

    /// PLT-R340 boundaries with their names; a focus change found while reconciling is stamped at its key.
    @Test func boundariesCarryTheirReasonsAndTheirKeysTime() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.press(Key.a)
        fixture.press(Key.left)
        fixture.publish(focus: PipelineFixtures.focus(generation: 2, pid: 200, bundle: PipelineFixtures.otherBundle))
        clock.sleep(until: clock.now().advanced(byMicroseconds: 5_000))
        let keyTime = clock.now()
        fixture.keyDown(Key.a)
        let found = boundaries(devRecords(capture))
        #expect(found.map(\.reason) == ["cursorMoved", "applicationChanged"])
        #expect(found.map(\.job) == ["navigation", "focusChanged"])
        #expect(found.last?.at == keyTime)
    }

    /// Control+Option+Command+Semicolon: consumed with its keyUp, a marker record and a confirmation request.
    @Test func theMarkerChordIsConsumedAndMarked() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        #expect(fixture.keyDown(semicolon, flags: markerFlags) == .swallow)
        #expect(fixture.lastOutcome == .consumedAsHotkey)
        #expect(fixture.keyDown(semicolon, flags: markerFlags, autorepeat: true) == .swallow)
        #expect(fixture.keyUp(semicolon, flags: markerFlags) == .swallow)
        let markers = devRecords(capture).filter {
            if case .marker(.chord, _) = $0 { return true }
            return false
        }
        #expect(markers.count == 1)
        #expect(capture.dev.takeAttention() == [.marker])
        #expect(fixture.queue.pop() == nil)  // no boundary job, nothing for the app
    }

    /// The chord is the marker only with exactly Control, Option and Command, and only in a running recorder.
    @Test func otherChordsAndAStoppedRecorderLeaveTheKeyAlone() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        #expect(fixture.press(semicolon, flags: markerFlags | Flag.shift) == .pass)
        #expect(fixture.press(semicolon, flags: Flag.control | Flag.command) == .pass)
        capture.dev.stop()
        #expect(fixture.press(semicolon, flags: markerFlags) == .pass)
        #expect(capture.dev.takeAttention().isEmpty)
    }

    /// PLT-R730: fail-open passes everything, the marker chord included.
    @Test func failOpenPassesTheMarkerChord() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(
            lifecycle: PipelineFixtures.lifecycle(phase: .starting), clock: clock, capture: capture)
        #expect(fixture.keyDown(semicolon, flags: markerFlags) == .pass)
    }

    /// A paused recorder still owns its chord (consumed) but records nothing.
    @Test func aPausedRecorderConsumesTheChordWithoutAMarker() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        capture.dev.pause()
        let fixture = PipelineFixture(clock: clock, capture: capture)
        #expect(fixture.keyDown(semicolon, flags: markerFlags) == .swallow)
        #expect(devRecords(capture).isEmpty)
        #expect(capture.dev.takeAttention().isEmpty)
    }

    /// A Backspace that edited asks for a readback; a plain one does not.
    @Test func aBackspaceThatEditsRequestsAReadback() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.typeKeys([Key.a, Key.backspace])
        #expect(capture.dev.takeAttention().isEmpty)
        fixture.typeKeys([Key.a, Key.s, Key.backspace])  // "á", then Backspace gives "a" back
        #expect(capture.dev.takeAttention() == [.backspaceEdit])
    }

    /// A committed word asks for a readback (the production engine reports the commit decision).
    @Test func aCommittedWordRequestsAReadback() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        let pipeline = KeyPipeline(
            context: fixture.context, factory: VietnameseCompositionEngineFactory(), clock: fixture.clock)
        for code in [Key.a, Key.space] {
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, at: clock.now()))
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, at: clock.now()))
        }
        let committed = steps(devRecords(capture)).last
        #expect(committed?.decision != nil)
        #expect(capture.dev.takeAttention() == [.commit])
    }

    /// PLT-R904A readback pause (incidents 1 and 10 of 2026-11-14): every key down and click the tap records tells
    /// the recorder when input last went down; key ups and modifier changes do not.
    @Test func keyDownsAndClicksMarkInputActivity() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        #expect(capture.dev.inputActivity.count == 0 && capture.dev.inputActivity.lastInput == nil)
        clock.advance(byMicroseconds: 5_000)
        fixture.typeKeys([Key.a, Key.s])
        #expect(capture.dev.inputActivity.count == 2)
        #expect(capture.dev.inputActivity.lastInput == clock.now())
        clock.advance(byMicroseconds: 5_000)
        fixture.flags(Key.shift, Flag.shift)
        #expect(capture.dev.inputActivity.count == 2)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0, at: clock.now()))
        #expect(capture.dev.inputActivity.count == 3 && capture.dev.inputActivity.lastInput == clock.now())
    }

    /// PLT-R905 rules: nothing from a secure field, not even the marker.
    @Test func aSecureFieldRecordsNothing() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(
            focus: PipelineFixtures.focus(field: PipelineFixtures.field(secure: true)), clock: clock, capture: capture)
        fixture.typeKeys([Key.a, Key.s])
        fixture.press(semicolon, flags: markerFlags)
        #expect(devRecords(capture).isEmpty)
        #expect(keyRecords(capture).isEmpty)
        #expect(capture.dev.takeAttention().isEmpty)
    }

    /// PLT-R304, PLT-R305: recording adds no allocation to the tap's steady state (the drain is the worker's side).
    @Test(.enabled(if: AllocationCounter.isAvailable, "sanitizer runtimes replace malloc and never call the hook"))
    func recordingAllocatesNothingOnTheTap() throws {
        let clock = ManualClock()
        let capture = try startedCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        let pipeline = KeyPipeline(
            context: fixture.context, factory: AllocationExcludingFactory(ScriptedEngineFactory()), clock: clock)
        let stream: [RawKeyEvent] = [Key.a, Key.a, Key.s, Key.space, Key.u, Key.w, Key.backspace, Key.left, Key.comma]
            .flatMap { [PipelineFixtures.keyEvent(.keyDown, $0), PipelineFixtures.keyEvent(.keyUp, $0)] }
        func drainAll() {
            while let job = fixture.queue.pop() {
                let sequence = PipelineFixture.sequence(of: job)
                if case .edit = job { fixture.feedback.record(.executed, for: sequence) }
                fixture.queue.finished(sequence, expectation: nil)
            }
            while capture.tapRecords.pop() != nil {}
            while capture.dev.tapRecords.pop() != nil {}
            _ = capture.dev.takeAttention()
        }
        func step(_ index: Int) {
            _ = pipeline.handle(stream[index % stream.count])
            guard index % 4 == 3 else { return }
            AllocationCounter.pause()
            drainAll()
            AllocationCounter.resume()
        }
        for index in 0..<(stream.count * 4) { step(index) }
        let counts = AllocationCounter.measure {
            var index = 0
            while index < 4_000 {
                step(index)
                index += 1
            }
        }
        #expect(counts.allocations == 0, "the tap path allocated \(counts.allocations) times")
        #expect(counts.deallocations == 0, "the tap path freed \(counts.deallocations) times")
    }
}
#endif
