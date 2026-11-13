// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R902, ENG-R906 (ADR 0005 "Implemented later"): the host reports the Caps Lock state of every key to the
// engine (`KeyInput.capsLock`), so a Telex bracket key, which has no case, gives an uppercase letter under Caps
// Lock. The flag comes from the event's own flags, read on the tap thread with no extra work (PLT-R304).

import AppModel
import Injection
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct KeyPipelineCapsLockTests {
    static let leftBracket: UInt16 = 0x21  // kVK_ANSI_LeftBracket
    static let rightBracket: UInt16 = 0x1E  // kVK_ANSI_RightBracket

    private func keyFeeds(_ log: EngineEventLog) -> [KeyInput] {
        log.feeds.compactMap { if case .key(let input) = $0 { input } else { nil } }
    }

    /// Scripted engine: every character key carries the Caps Lock bit of its own event.
    @Test func everyKeyCarriesItsCapsLockState_ENGR906() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.press(Self.leftBracket, flags: Flag.capsLock)
        fixture.press(Key.s, flags: Flag.capsLock | Flag.shift)
        fixture.press(Key.e)
        #expect(
            keyFeeds(fixture.log) == [
                KeyInput("a"), KeyInput("[", capsLock: true), KeyInput("s", capsLock: true), KeyInput("e"),
            ])
    }

    /// Keypad keys keep `fromKeypad` next to the Caps Lock bit (PLT-R355).
    @Test func keypadKeysKeepFromKeypadWithCapsLock() {
        let fixture = PipelineFixture()
        fixture.press(Key.keypad1, flags: Flag.capsLock)
        #expect(keyFeeds(fixture.log) == [KeyInput("1", fromKeypad: true, capsLock: true)])
    }

    // MARK: Real engine

    typealias RealPipeline = KeyPipeline<VietnameseCompositionEngineFactory, ManualClock>

    private static func realFixture(bracketKeys: Bool = true) -> (PipelineFixture, RealPipeline) {
        var settings = DefaultSettings.v1
        settings.telexBracketKeys = bracketKeys
        let catalog = EngineBridge.catalog(settings: settings, resources: .empty, revision: 0)
        let snapshot = TapSettingsSnapshot(
            generation: 1, engines: catalog, toggleHotkey: .defaultToggle, restoreHotkey: nil,
            macrosInEnglishMode: false, rememberPerApp: true)
        let fixture = PipelineFixture(settings: snapshot)
        let pipeline = KeyPipeline(
            context: fixture.context, factory: VietnameseCompositionEngineFactory(), clock: fixture.clock)
        return (fixture, pipeline)
    }

    private static func type(
        _ keys: [(UInt16, UInt64)], fixture: PipelineFixture,
        pipeline: RealPipeline
    ) -> [EditJob] {
        var edits: [EditJob] = []
        for (code, flags) in keys {
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyDown, code, flags: flags, at: fixture.clock.now()))
            for job in fixture.popJobs() {
                guard let edit = job.edit else { continue }
                edits.append(edit)
                fixture.queue.finished(edit.sequence, expectation: nil)
                fixture.feedback.record(.executed, for: edit.sequence)
            }
            _ = pipeline.handle(PipelineFixtures.keyEvent(.keyUp, code, flags: flags, at: fixture.clock.now()))
            _ = fixture.popJobs()
        }
        return edits
    }

    /// Caps Lock `[` gives `Ơ` and Caps Lock `]` gives `Ư`; without Caps Lock they stay lowercase.
    @Test(arguments: [(leftBracket, "Ơ", "ơ"), (rightBracket, "Ư", "ư")])
    func bracketKeyFollowsCapsLockThroughTheRealEngine(code: UInt16, upper: String, lower: String) {
        let (locked, lockedPipeline) = Self.realFixture()
        let lockedEdits = Self.type([(code, Flag.capsLock)], fixture: locked, pipeline: lockedPipeline)
        #expect(lockedEdits.map(\.insertion) == [upper])
        let (plain, plainPipeline) = Self.realFixture()
        #expect(Self.type([(code, 0)], fixture: plain, pipeline: plainPipeline).map(\.insertion) == [lower])
    }

    /// `T` typed with Caps Lock, then Caps Lock `[`: the token reads `TƠ` (the bracket letter follows the key's
    /// own Caps Lock state, ENG-R906), where the same keys without Caps Lock on the bracket give `Tơ`.
    @Test func bracketAfterACapitalFollowsItsOwnCapsLockState() {
        let tKey: UInt16 = 0x11
        let (locked, lockedPipeline) = Self.realFixture()
        let edits = Self.type(
            [(tKey, Flag.capsLock), (Self.leftBracket, Flag.capsLock)], fixture: locked, pipeline: lockedPipeline)
        #expect(edits.last?.insertion.hasSuffix("Ơ") == true)
        let (shifted, shiftedPipeline) = Self.realFixture()
        let mixed = Self.type([(tKey, Flag.shift), (Self.leftBracket, 0)], fixture: shifted, pipeline: shiftedPipeline)
        #expect(mixed.last?.insertion.hasSuffix("ơ") == true)
    }
}
