// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R357 on the tap: a commit whose engine output revises the previous token is one `.revision` job, pushed
// before the replay of the boundary key (Space, punctuation or Return), with the first character's keycode
// (PLT-R405), the previous token for the PLT-R342 read-back, and verification where the rule verifies re-entry.
// The undo (ENG-R829) arrives as a restore edit with no active word (PLT-R353). Collision signals reach main with
// their recordable flag (PLT-R914). A new learned memory is swapped in at a hard boundary only (ENG-R865). Scripted
// engine: a token with `q` committed after one word and one space restores that word's raw keys.

import AppModel
import Injection
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private func fixture(
    variant: EngineVariant = .default, verifyReentry: VerifyReentry = .whenReadable, secure: Bool = false,
    restore: HotkeyBinding? = .key(KeyCode(rawValue: Key.escape))
) -> PipelineFixture {
    PipelineFixture(
        settings: PipelineFixtures.settings(restore: restore),
        focus: PipelineFixtures.focus(
            decision: PipelineFixtures.decision(variant: variant, verifyReentry: verifyReentry),
            field: PipelineFixtures.field(secure: secure)))
}

/// Types `keys` one press at a time, finishing every job before the next press.
private func type(_ keys: [UInt16], into fixture: PipelineFixture) {
    for key in keys {
        fixture.press(key)
        fixture.completeJobs()
    }
}

/// `á qa`: `as` is shown `á`; `qa` then revises it at the boundary.
private let revisingWord: [UInt16] = [Key.a, Key.s, Key.space, Key.q, Key.a]

@Suite struct KeyPipelineRevisionTests {
    /// One `.revision` job over the previous token, the space and the current token, then the boundary key.
    @Test func aRevisingCommitIsOneRevisionJobBeforeTheBoundaryKeyPLTR357() throws {
        let fixture = fixture()
        type(revisingWord, into: fixture)
        fixture.keyDown(Key.space)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay])
        let edit = try #require(jobs.first?.edit)
        #expect(edit.kind == .revision)
        #expect(edit.deleteCount == 4 && edit.insertion == "as qa")
        #expect(edit.revision?.previous?.text == "á")
        #expect(edit.revision?.currentDisplay == "qa")
        #expect(edit.revision?.expectedText == "á qa")
        #expect(edit.replacedText == nil, "the worker builds the expected text")
        #expect(edit.verifyBeforeApply)
        #expect(edit.trigger == nil)
        #expect(edit.keyCodes.trigger.rawValue == Key.space)
        #expect(edit.keyCodes.firstCharacter?.rawValue == Key.a, "PLT-R405: never the Space keycode")
        #expect(jobs.last?.replayed?.keyCode.rawValue == Key.space)
    }

    /// P0-3, D29 at Return: the fixed line reaches the app before Return.
    @Test func atReturnTheRevisionPrecedesTheReplayedReturn() throws {
        let fixture = fixture()
        type(revisingWord, into: fixture)
        fixture.press(Key.returnKey)
        let jobs = fixture.popJobs()
        #expect(jobs.first?.edit?.kind == .revision)
        #expect(jobs.dropFirst().first?.replayed?.keyCode.rawValue == Key.returnKey)
    }

    /// PLT-R357: with the rule's flag off the engine computes no revision (16 variants, ENG-R829).
    @Test func noRevisionWhereTheRuleTurnsItOff() {
        let variant = EngineVariant(appContext: .general, englishRestore: true, macros: true, lookaheadRevision: false)
        let fixture = fixture(variant: variant)
        type(revisingWord, into: fixture)
        fixture.press(Key.space)
        let jobs = fixture.popJobs()
        #expect(!jobs.contains { $0.edit?.kind == .revision })
    }

    /// PLT-R342: a rule with `verifyReentry: never` applies the revision without reading back.
    @Test func noReadBackWhereTheRuleNeverVerifies() throws {
        let fixture = fixture(verifyReentry: .never)
        type(revisingWord, into: fixture)
        fixture.press(Key.space)
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.kind == .revision && !edit.verifyBeforeApply)
    }

    /// The previous token's text is what its own commit left: a restored token's raw keys.
    @Test func thePreviousTokenOfARestoredCommitIsItsRawKeys() throws {
        let fixture = fixture()
        // `xas` is shown `xá` and restored to `xas` at the space (the scripted English mark `x`); `qa` revises
        // nothing then, because the restored word shows its raw keys already.
        type([Key.x, Key.a, Key.s, Key.space, Key.q, Key.a], into: fixture)
        fixture.press(Key.space)
        #expect(!fixture.popJobs().contains { $0.edit?.kind == .revision })
    }

    /// ENG-R829, PLT-R353: the restore key right after a revising commit undoes it with an edit wider than the
    /// (empty) active display; the key is consumed as the hotkey and the undo reports a strong signal.
    @Test func theUndoIsARestoreWiderThanTheActiveDisplay() throws {
        let fixture = fixture()
        type(revisingWord + [Key.space], into: fixture)
        let verdict = fixture.press(Key.escape)
        #expect(verdict == .swallow)
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.kind == .restore)
        #expect(edit.replacedText == nil)
        #expect(edit.deleteCount == "as qa ".count && edit.insertion == "á qa ")
        let signals = fixture.mainNotices().compactMap { notice -> [CollisionSignal]? in
            if case .collisionSignals(let signals, true) = notice { return signals }
            return nil
        }
        #expect(signals.flatMap { $0 }.map(\.strength) == [.strong])
    }

    /// PLT-R914: signals leave the tap marked not recordable where the rule turns English restore off.
    @Test func signalsAreMarkedNotRecordableWithoutEnglishRestore() {
        let variant = EngineVariant(appContext: .general, englishRestore: false, macros: true)
        let fixture = fixture(variant: variant)
        type([Key.a, Key.s], into: fixture)
        fixture.press(Key.escape)  // toggle on the active word: a strong signal
        let flags = fixture.mainNotices().compactMap { notice -> Bool? in
            if case .collisionSignals(_, let recordable) = notice { return recordable }
            return nil
        }
        #expect(flags == [false])
    }

    /// ENG-R865: a catalog with a new learned memory and the same settings revision is swapped in only once the
    /// engine is clean (after a hard boundary): the word being typed survives.
    @Test func aNewMemoryIsSwappedInAtTheNextHardBoundary() {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(engineRevision: 1))
        type([Key.a, Key.s], into: fixture)
        let made = fixture.log.entries.filter { if case .made = $0 { true } else { false } }.count
        let withMemory = TapSettingsSnapshot(
            generation: 2, engines: EngineCatalog(engines: [:], revision: 1, memoryRevision: 1),
            toggleHotkey: .defaultToggle, restoreHotkey: nil, macrosInEnglishMode: false, rememberPerApp: true)
        fixture.publish(settings: withMemory)
        type([Key.a], into: fixture)
        let madeAfterKey = fixture.log.entries.filter { if case .made = $0 { true } else { false } }.count
        #expect(madeAfterKey == made, "no rebuild in the middle of a word")
        #expect(fixture.log.events.suffix(1) == [.key(KeyInput("a"))])
        type([Key.returnKey, Key.a], into: fixture)
        let madeAfterReturn = fixture.log.entries.filter { if case .made = $0 { true } else { false } }.count
        #expect(madeAfterReturn == made + 1)
    }

    /// ENG-R865: a new settings revision still rebuilds at once (PLT-R340), as before.
    @Test func aNewSettingsRevisionStillRebuildsAtOnce() {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(engineRevision: 1))
        type([Key.a], into: fixture)
        let made = fixture.log.entries.filter { if case .made = $0 { true } else { false } }.count
        fixture.publish(settings: PipelineFixtures.settings(generation: 2, engineRevision: 2))
        type([Key.a], into: fixture)
        #expect(fixture.log.entries.filter { if case .made = $0 { true } else { false } }.count == made + 1)
    }
}
