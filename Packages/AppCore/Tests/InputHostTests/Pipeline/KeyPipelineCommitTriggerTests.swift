// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R405 in the pipeline for edits triggered by Return, keypad Enter, Tab and Space: the job carries the keycode of
// a letter of the edit (`JobKeyCodes.firstCharacter`), and the trigger key itself follows as exactly one replay of
// the physical event, after the edit (P0-3, ADR 0308). W8-F.

import AppModel
import Injection
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private enum Code {
    static let t: UInt16 = 0x11
    static let h: UInt16 = 0x04
    static let o: UInt16 = 0x1F
    static let r: UInt16 = 0x0F
}

@Suite struct KeyPipelineCommitTriggerTests {
    static let triggers = [Key.returnKey, Key.keypadEnter, Key.tab, Key.space]

    /// The scripted engine restores `axs` at any separator (ENG-R803): the edit types on the keycode of `a`, and the
    /// separator key reaches the app once, after the edit, on its own keycode.
    @Test(arguments: Self.triggers)
    func aRestoreAtTheTriggerInsertsOnALetterKeycodeAndReplaysTheKeyOncePLTR405(key: UInt16) throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.x, Key.s])  // "áx" displayed, raw "axs", marked English
        fixture.completeJobs()
        #expect(fixture.keyDown(key) == .swallow)
        let jobs = fixture.popJobs()
        let editIndex = try #require(jobs.firstIndex { $0.kind == .edit })
        let edit = try #require(jobs[editIndex].edit)
        #expect(edit.insertion == "axs")
        #expect(edit.keyCodes.trigger == KeyCode(rawValue: key))
        #expect(edit.keyCodes.firstCharacter == KeyCode(rawValue: Key.a))
        #expect(edit.trigger == nil, "the key itself is the replay (ADR 0308)")
        let replays = jobs.indices.filter { jobs[$0].kind == .replay }
        #expect(replays.count == 1)
        let replayIndex = try #require(replays.first)
        #expect(replayIndex > editIndex)
        #expect(jobs[replayIndex].replayed?.keyCode == KeyCode(rawValue: key))
        #expect(jobs[replayIndex].replayed?.kind == .keyDown)
    }

    /// A character key keeps triggering on its own keycode (PLT-R405): only keys with an action of their own move
    /// the insertion to a letter.
    @Test func aCommaKeepsItsOwnKeycode() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.x, Key.s])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.comma) == .swallow)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.keyCodes.trigger == KeyCode(rawValue: Key.comma))
        #expect(edit.keyCodes.firstCharacter == nil)
    }

    @Test func theLetterSkipsCharactersTypedByActionKeys() {
        let table = PipelineFixtures.qwertyTable()
        #expect(
            KeyPipeline<ScriptedEngineFactory, ManualClock>.letterKeyCode(
                insertion: " \tĐà a", replaced: "", table: table) == KeyCode(rawValue: Key.a))
        #expect(
            KeyPipeline<ScriptedEngineFactory, ManualClock>.letterKeyCode(insertion: " ", replaced: "  ", table: table)
                == nil)
    }
}

/// The real engine: the ENG-R532 commit spelling at Return, keypad Enter, Tab or Space.
@Suite struct KeyPipelineRealEngineCommitTriggerTests {
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

    /// Types `codes` (keyDown, then keyUp), executing every edit at once; returns the jobs of the last keyDown.
    private static func type(_ codes: [UInt16], fixture: PipelineFixture, pipeline: RealPipeline) -> [InjectionJob] {
        var last: [InjectionJob] = []
        for code in codes {
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, at: fixture.clock.now()))
            last = fixture.popJobs()
            for job in last { fixture.queue.finished(PipelineFixture.sequence(of: job), expectation: nil) }
            for edit in last.compactMap(\.edit) { fixture.feedback.record(.executed, for: edit.sequence) }
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, at: fixture.clock.now()))
            _ = fixture.popJobs()
        }
        return last
    }

    @Test(arguments: KeyPipelineCommitTriggerTests.triggers)
    func thuoAtTheTriggerTypesOnALetterKeycodePLTR405(key: UInt16) throws {
        let (fixture, pipeline) = Self.realFixture()
        _ = Self.type([Code.t, Code.h, Key.u, Code.o, Key.w, Code.r], fixture: fixture, pipeline: pipeline)
        let jobs = Self.type([key], fixture: fixture, pipeline: pipeline)
        let editIndex = try #require(jobs.firstIndex { $0.kind == .edit })
        let edit = try #require(jobs[editIndex].edit)
        #expect(edit.insertion.hasSuffix("uở"), "ENG-R532 commit spelling")
        let table = PipelineFixtures.qwertyTable()
        let first = try #require(edit.insertion.first)
        #expect(edit.keyCodes.trigger == KeyCode(rawValue: key))
        #expect(edit.keyCodes.firstCharacter == table.keyCode(producing: first))
        #expect(edit.keyCodes.firstCharacter.map(JobKeyCodes.isActionKey) == false)
        let replays = jobs.indices.filter { jobs[$0].kind == .replay }
        #expect(replays.count == 1 && replays.allSatisfy { $0 > editIndex })
        #expect(replays.first.flatMap { jobs[$0].replayed?.keyCode } == KeyCode(rawValue: key))
    }
}
