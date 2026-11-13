// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typing-trace records from the tap (PLT-R905, PRD-R46): keys with keycode, flags, layout character and outcome,
// the engine's decision, clicks; nothing while secure input or a secure field is active (PLT-R387, PLT-R398A).

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

private func recordingCapture(clock: ManualClock) throws -> CaptureController {
    let capture = CaptureController(
        directory: URL(fileURLWithPath: "/captures", isDirectory: true), fileSystem: InMemoryFileSystem(),
        wallClock: FixedWallClock(), clock: clock, scheduler: ManualScheduler(clock: clock))
    _ = try capture.start(duration: .seconds(60))
    return capture
}

private func drained(_ capture: CaptureController) -> [CaptureRecord] {
    var records: [CaptureRecord] = []
    while let record = capture.tapRecords.pop() { records.append(record) }
    return records
}

private func keys(_ records: [CaptureRecord]) -> [KeyCaptureRecord] {
    records.compactMap { record in
        if case .key(let key) = record { return key }
        return nil
    }
}

@Suite struct TypingTraceCaptureTests {
    /// PLT-R905: every physical key, then the engine decision of the key that produced an edit.
    @Test func keysAndEngineDecisionsAreRecorded() throws {
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // "â"
        let records = drained(capture)
        let recorded = keys(records)
        #expect(recorded.map(\.kind) == [.keyDown, .keyUp, .keyDown])
        #expect(recorded.map(\.character.string) == ["a", "a", "a"])
        #expect(recorded.map(\.outcome) == [.passed, .passed, .consumedForEdit])
        #expect(recorded.allSatisfy { $0.keyCode == Key.a && $0.flags == 0 })
        guard case .engine(let deleteCount, let insert, _) = records.last else {
            Issue.record("the engine line follows its key line")
            return
        }
        #expect(deleteCount == 1 && insert == "â")
    }

    /// PLT-R905: a click is part of the trace; modifiers are recorded without a character.
    @Test func clicksAndModifiersAreRecorded() throws {
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        fixture.flags(Key.shift, Flag.shift)
        let recorded = keys(drained(capture))
        #expect(recorded.map(\.kind) == [.mouseDown, .flagsChanged])
        #expect(recorded.last?.flags == Flag.shift && recorded.last?.character.count == 0)
    }

    /// PLT-R905, PLT-R387: a secure field records nothing, even before the main thread opens the capture gap.
    @Test func aSecureFieldRecordsNothing() throws {
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let fixture = PipelineFixture(
            focus: PipelineFixtures.focus(field: PipelineFixtures.field(secure: true)), clock: clock, capture: capture)
        fixture.typeKeys([Key.a, Key.s])
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        #expect(drained(capture).isEmpty)
    }

    /// PLT-R905, PLT-R398A: OS secure input records nothing until key evidence resumes it (the main thread ends
    /// its gap at the same moment).
    @Test func secureInputRecordsNothing() throws {
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let fixture = PipelineFixture(
            secureInput: SecureInputSnapshot(generation: 1, enabled: true, holder: nil), clock: clock, capture: capture)
        fixture.flags(Key.shift, Flag.shift)
        fixture.flags(Key.shift, 0)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        #expect(drained(capture).isEmpty)
    }

    /// Nothing is pushed when no capture runs.
    @Test func nothingWithoutARunningCapture() throws {
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/captures", isDirectory: true), fileSystem: InMemoryFileSystem(),
            wallClock: FixedWallClock(), clock: clock, scheduler: ManualScheduler(clock: clock))
        let fixture = PipelineFixture(clock: clock, capture: capture)
        fixture.typeKeys([Key.a, Key.a])
        #expect(drained(capture).isEmpty)
    }
}
