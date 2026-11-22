// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R706 on the tap (REG-42, the product owner's report of 23/11/2026 on 1.1.0-beta.1): typing
// `Thanks Giving bar` and a space restores `bả` to `bar` (rule L10, the English run), and Escape right after now puts
// `bả` back. The engine answers the toggle with an edit that has no active word, which `restoreLastWord` already
// injects as a restore job wider than the empty active display (PLT-R353, as for ENG-R829 and ENG-R1117), and the
// toggle's learning signal and strong collision signal go to main. Where the rule turns the restore key off, Escape
// passes untouched and the engine never sees a toggle. Real engine, bundled data, the default catalog.

import AppModel
import Injection
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine
import VietnameseEngineData

@testable import InputHost

@Suite struct KeyPipelineContextRestoreUndoTests {
    typealias RealPipeline = KeyPipeline<VietnameseCompositionEngineFactory, ManualClock>

    private static let resources: Resources = {
        do {
            return try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        } catch {
            return .empty
        }
    }()

    private static let escape = HotkeyBinding.key(KeyCode(rawValue: Key.escape))

    /// A pipeline over the real engines of the default catalog with the bundled data, Escape as the restore key, and
    /// a focus whose rule keeps the restore key on or turns it off.
    private static func realFixture(restoreHotkeyEnabled: Bool = true) -> (PipelineFixture, RealPipeline) {
        let catalog = EngineBridge.catalog(settings: DefaultSettings.v1, resources: resources, revision: 0)
        let snapshot = TapSettingsSnapshot(
            generation: 1, engines: catalog, toggleHotkey: .defaultToggle, restoreHotkey: escape,
            macrosInEnglishMode: false, rememberPerApp: true)
        let fixture = PipelineFixture(
            settings: snapshot,
            focus: PipelineFixtures.focus(
                decision: PipelineFixtures.decision(restoreHotkeyEnabled: restoreHotkeyEnabled)))
        let pipeline = KeyPipeline(
            context: fixture.context, factory: VietnameseCompositionEngineFactory(), clock: fixture.clock)
        return (fixture, pipeline)
    }

    /// Presses one key (with its modifier flags) and finishes every job; returns the keyDown's verdict and the edits.
    @discardableResult
    private static func press(
        _ code: UInt16, flags: UInt64 = 0, fixture: PipelineFixture, pipeline: RealPipeline
    ) -> (TapVerdict, [EditJob]) {
        let verdict = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, flags: flags, at: fixture.clock.now()))
        // Every job (edits and replays) is finished as executed, nothing left in flight, before the next event.
        let edits = fixture.completeJobs().compactMap(\.edit)
        _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, flags: flags, at: fixture.clock.now()))
        fixture.completeJobs()
        return (verdict, edits)
    }

    /// Types `text` on the U.S. layout of the fixture (Shift for capitals).
    private static func type(_ text: String, fixture: PipelineFixture, pipeline: RealPipeline) {
        for character in text {
            if character == "\n" {
                press(Key.returnKey, fixture: fixture, pipeline: pipeline)
                continue
            }
            guard let (code, flags) = HostRig.key(producing: character, in: PipelineFixtures.qwertyTable()) else {
                Issue.record("no key produces \(character)")
                continue
            }
            press(code.rawValue, flags: flags, fixture: fixture, pipeline: pipeline)
        }
    }

    private static func learningSignals(_ notices: [MainNotice]) -> [LearningSignal] {
        notices.compactMap { notice in
            if case .learning(let signal, _) = notice { return signal }
            return nil
        }
    }

    private static func collisionSignals(_ notices: [MainNotice]) -> [CollisionSignal] {
        notices.flatMap { notice -> [CollisionSignal] in
            if case .collisionSignals(let signals, true) = notice { return signals }
            return []
        }
    }

    @Test func theBundledDataLoads() {
        #expect(Self.resources.ambiguity["bar"] != nil, "`bar` is an ambiguity row of the bundled data")
    }

    /// REG-42: Escape right after the commit is consumed and answered with one restore job over `ar ` (the common
    /// prefix `b` stays) that types `ả ` back; the signals reach main with the app typed in; the second Escape passes.
    @Test func escapeRightAfterTheEnglishRunRestoreIsConsumed_ENGR706() throws {
        let (fixture, pipeline) = Self.realFixture()
        Self.type("Thanks Giving bar ", fixture: fixture, pipeline: pipeline)
        let before = fixture.mainNotices().count
        let (verdict, edits) = Self.press(Key.escape, fixture: fixture, pipeline: pipeline)
        #expect(verdict == .swallow)
        let edit = try #require(edits.first)
        #expect(edit.kind == .restore && edits.count == 1)
        #expect(edit.deleteCount == "ar ".count && edit.insertion == "ả ")
        #expect(edit.replacedText == nil && edit.trigger == nil)
        #expect(pipeline.keyState.lastCommit == nil)
        let notices = Array(fixture.mainNotices().dropFirst(before))
        #expect(Self.learningSignals(notices) == [.preferredVietnamese(raw: "bar")])
        #expect(
            notices.contains {
                if case .learning(_, let bundle) = $0 { bundle == PipelineFixtures.focus().app?.bundle } else { false }
            })
        #expect(
            Self.collisionSignals(notices) == [
                CollisionSignal(word: "bar", context: .afterEnglish, side: .vietnamese, strength: .strong)
            ])
        // ENG-R702: the second press passes through untouched and changes nothing.
        let (second, secondEdits) = Self.press(Key.escape, fixture: fixture, pipeline: pipeline)
        #expect(second == .pass && secondEdits.isEmpty)
    }

    /// PLT-R353: where the rule turns the restore key off, Escape passes untouched, the engine never sees the toggle
    /// and nothing reaches main.
    @Test func whereTheRuleTurnsTheKeyOffEscapePasses() {
        let (fixture, pipeline) = Self.realFixture(restoreHotkeyEnabled: false)
        Self.type("Thanks Giving bar ", fixture: fixture, pipeline: pipeline)
        let before = fixture.mainNotices().count
        let (verdict, edits) = Self.press(Key.escape, fixture: fixture, pipeline: pipeline)
        #expect(verdict == .pass && edits.isEmpty)
        let notices = Array(fixture.mainNotices().dropFirst(before))
        #expect(Self.learningSignals(notices).isEmpty && Self.collisionSignals(notices).isEmpty)
    }

    /// ENG-R706, ENG-R829: after Return the history is cleared, so Escape passes; a word the token alone restores
    /// (`best` has an `en` row) leaves Escape its meaning.
    @Test func escapePassesWhereThereIsNothingToUndo() {
        for text in ["Thanks Giving bar\n", "the best "] {
            let (fixture, pipeline) = Self.realFixture()
            Self.type(text, fixture: fixture, pipeline: pipeline)
            let (verdict, edits) = Self.press(Key.escape, fixture: fixture, pipeline: pipeline)
            #expect(verdict == .pass && edits.isEmpty, "\(text.debugDescription)")
        }
    }
}
