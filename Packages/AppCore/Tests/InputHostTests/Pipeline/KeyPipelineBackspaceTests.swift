// SPDX-License-Identifier: GPL-3.0-or-later
//
// Backspace and the delete keys in the pipeline (PLT-R351, PLT-R352, PLT-R405, ENG-R714, ENG-R1010): which keys
// reach the engine as Backspace, which are resets, the keycode a Backspace edit inserts with, and the guard that
// a Backspace-triggered edit never deletes more than the active token's display (Pa, 2026-11-14, items 2 and 3).

import AppModel
import Injection
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private enum Code {
    static let h: UInt16 = 0x04
    static let o: UInt16 = 0x1F
    static let f: UInt16 = 0x03
    static let n: UInt16 = 0x2D
    static let t: UInt16 = 0x11
    static let r: UInt16 = 0x0F
    static let b: UInt16 = 0x0B
}

@Suite struct KeyPipelineDeleteKeyTests {
    /// ENG-R1010, PLT-R352: Command+Backspace (delete to the line start) and Control+Backspace are chords; the app
    /// deletes text the engine cannot count, so they reset and are never fed as Backspace.
    @Test(arguments: [Flag.command, Flag.control, Flag.command | Flag.shift, Flag.control | Flag.option])
    func commandOrControlBackspaceResetsAndIsNotFed(flags: UInt64) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.backspace, flags: flags) == .pass)
        #expect(fixture.log.resets == [.shortcut])
        #expect(!fixture.log.feeds.contains(.backspace))
    }

    /// Option+Backspace deletes a word: navigation, a reset, never fed (PLT-R352, ENG-R1010).
    @Test func optionBackspaceWithShiftIsStillAWordDeletion() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.backspace, flags: Flag.option | Flag.shift) == .pass)
        #expect(fixture.log.resets == [.cursorMoved])
        #expect(!fixture.log.feeds.contains(.backspace))
    }

    /// Forward Delete with any modifier is a reset and never fed (ENG-R1010, PLT-R340).
    @Test(arguments: [0, Flag.option, Flag.shift, Flag.command, Flag.control])
    func forwardDeleteWithModifiersResets(flags: UInt64) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.forwardDelete, flags: flags) == .pass)
        #expect(fixture.log.resets.count == 1)
        #expect(fixture.log.resets.allSatisfy { $0 == .forwardDelete || $0 == .shortcut })
        #expect(!fixture.log.feeds.contains(.backspace))
    }

    /// Shift+Backspace deletes one character like Backspace, so the engine hears it.
    @Test func shiftBackspaceIsFedAsBackspace() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.backspace, flags: Flag.shift)
        #expect(fixture.log.feeds.last == .backspace)
        #expect(fixture.log.resets.isEmpty)
    }

    /// PLT-R405: a Backspace edit carries the keycode of a character of the edit, never `kVK_Delete`. The scripted
    /// engine answers Backspace over `á` with an edit (delete `á`, insert `a`).
    @Test func aBackspaceEditCarriesALetterKeycodePLTR405() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.press(Key.s)
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.backspace) == .swallow)
        let job = try #require(fixture.popJobs().compactMap(\.edit).last)
        #expect(job.kind == .backspaceRecompose)
        #expect(job.keyCodes.trigger == .delete)
        #expect(job.keyCodes.firstCharacter == KeyCode(rawValue: Key.a))
    }
}

/// The real engine through the pipeline.
@Suite struct KeyPipelineRealEngineBackspaceTests {
    typealias RealPipeline = KeyPipeline<VietnameseCompositionEngineFactory, ManualClock>

    private static func realFixture() -> (PipelineFixture, RealPipeline) {
        let catalog = EngineBridge.catalog(settings: DefaultSettings.v1, resources: .empty, revision: 0)
        let snapshot = TapSettingsSnapshot(
            generation: 1, engines: catalog, toggleHotkey: .defaultToggle, restoreHotkey: nil,
            macrosInEnglishMode: false, rememberPerApp: true)
        let fixture = PipelineFixture(settings: snapshot)
        let pipeline = KeyPipeline(
            context: fixture.context, factory: VietnameseCompositionEngineFactory(), clock: fixture.clock)
        return (fixture, pipeline)
    }

    /// Presses each key; returns the verdict of the last keyDown and every edit job, executed as they come.
    private static func press(_ codes: [UInt16], fixture: PipelineFixture, pipeline: RealPipeline) -> (
        TapVerdict?, [EditJob]
    ) {
        var verdict: TapVerdict?
        var edits: [EditJob] = []
        for code in codes {
            verdict = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, at: fixture.clock.now()))
            for job in fixture.popJobs() {
                guard let edit = job.edit else { continue }
                edits.append(edit)
                fixture.queue.finished(edit.sequence, expectation: nil)
                fixture.feedback.record(.executed, for: edit.sequence)
            }
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, at: fixture.clock.now()))
            _ = fixture.popJobs()
        }
        return (verdict, edits)
    }

    /// REG-31: `thuowr` + Backspace leaves `thư`, so the app deletes the one character itself (ENG-R712).
    @Test func deletingTheHornedOOfOneWPassesThrough() {
        let (fixture, pipeline) = Self.realFixture()
        _ = Self.press([Code.t, Code.h, Key.u, Code.o, Key.w, Code.r], fixture: fixture, pipeline: pipeline)
        let (verdict, edits) = Self.press([Key.backspace], fixture: fixture, pipeline: pipeline)
        #expect(verdict == .pass)
        #expect(edits.isEmpty)
    }

    /// W240: traditional `hoafn` + Backspace relocates the tone, an edit; it inserts with the keycode of `a`, the
    /// first character of `òa` the layout types, not with `kVK_Delete` (PLT-R405).
    @Test func aToneRelocationAfterBackspaceInsertsWithALetterKeycode() throws {
        let (fixture, pipeline) = Self.realFixture()
        _ = Self.press([Code.h, Code.o, Key.a, Code.f, Code.n], fixture: fixture, pipeline: pipeline)
        let (verdict, edits) = Self.press([Key.backspace], fixture: fixture, pipeline: pipeline)
        #expect(verdict == .swallow)
        let edit = try #require(edits.last)
        #expect(edit.kind == .backspaceRecompose)
        #expect(edit.insertion == "òa" && edit.deleteCount == 3)
        #expect(edit.keyCodes.firstCharacter == KeyCode(rawValue: Key.a))
    }
}

/// ENG-R714 guard: an engine whose Backspace edit deletes more than its display.
private final class OverDeletingLog: @unchecked Sendable {
    let events = Mutex([EngineEvent]())
}

private struct OverDeletingEngine: CompositionEngine {
    let log: OverDeletingLog
    var activeDisplay = ""

    mutating func handle(_ event: EngineEvent) -> EngineOutput {
        log.events.withLock { $0.append(event) }
        switch event {
        case .key(let input):
            activeDisplay.append(input.character)
            return EngineOutput(action: .passThrough, composingText: activeDisplay)
        case .backspace:
            let count = activeDisplay.count + 2
            activeDisplay = ""
            let edit = TextEdit(deleteCount: count, deleteUTF16Count: count, insert: "")
            return EngineOutput(action: .edit(edit, thenPassThrough: false), composingText: "")
        case .restoreToggle, .reset:
            activeDisplay = ""
            return EngineOutput(action: .passThrough, composingText: "")
        }
    }
}

private struct OverDeletingFactory: CompositionEngineFactory {
    let log: OverDeletingLog
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> OverDeletingEngine {
        OverDeletingEngine(log: log)
    }
}

@Suite struct KeyPipelineBackspaceGuardTests {
    /// PLT-R352, ENG-R714: a Backspace edit larger than the active token's display is never applied; the Backspace
    /// passes through (the app deletes one character) and the composition is reset.
    @Test func aBackspaceEditNeverDeletesMoreThanTheTokenENGR714() {
        let log = OverDeletingLog()
        let fixture = PipelineFixture()
        let pipeline = KeyPipeline(context: fixture.context, factory: OverDeletingFactory(log: log), clock: fixture.clock)
        for code in [Key.a, Code.b] {
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, at: fixture.clock.now()))
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, at: fixture.clock.now()))
        }
        _ = fixture.popJobs()
        let verdict = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, Key.backspace, at: fixture.clock.now()))
        #expect(verdict == .pass)
        #expect(fixture.popJobs().compactMap(\.edit).isEmpty)
        let events = log.events.withLock { $0 }
        #expect(events.suffix(2).first == .backspace)
        if case .reset = events.last {} else { Issue.record("the composition was not reset: \(events)") }
    }
}
