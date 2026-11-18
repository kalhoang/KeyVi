// SPDX-License-Identifier: GPL-3.0-or-later
//
// Review hardening of the pipeline: toggle sequences after a tap recreation (PLT-R391, PLT-R731, contracts.md
// 10.4), re-entry verification only for committed words (PLT-R342), autorepeat never toggles (PRD-R14), live
// settings that keep the word (PRD-R27, PLT-R340), the key after a dead key (PLT-R354), restores that never
// replay their hotkey (PLT-R353) and focus republications without a field token (PLT-R210).

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private func tapControlShift(_ fixture: PipelineFixture) {
    fixture.flags(Key.control, Flag.control)
    fixture.flags(Key.shift, Flag.control | Flag.shift)
    fixture.flags(Key.shift, Flag.control)
    fixture.flags(Key.control, 0)
}

private func toggleSequences(_ fixture: PipelineFixture) -> [UInt64] {
    fixture.mainNotices().compactMap {
        if case .modeToggled(let sequence, _, _) = $0 { return sequence }
        return nil
    }
}

@Suite struct ToggleSequenceRecoveryTests {
    /// PLT-R731, ADR 0309: a recreated tap builds a new pipeline over a focus snapshot that already applied
    /// toggles; the tap's own next toggle must outrank them or its override is ignored (contracts.md 10.4).
    @Test func toggleAfterTapRecreationOutranksTheAppliedSequencePLTR391() {
        let fixture = PipelineFixture(focus: PipelineFixtures.focus(appliedToggleSequence: 5))
        tapControlShift(fixture)
        fixture.typeKeys([Key.a, Key.a])
        #expect(fixture.log.feeds.isEmpty)  // EN at once, not after the ax thread republishes
        #expect(toggleSequences(fixture) == [6])
    }

    /// The counter stays above anything the ax thread applied later (a toggle made elsewhere, for example
    /// from the menu, is applied with a higher sequence).
    @Test func toggleStaysAboveALaterAppliedSequence() {
        let fixture = PipelineFixture()
        tapControlShift(fixture)  // #1: EN
        var applied = PipelineFixtures.focus(generation: 2, mode: .english, appliedToggleSequence: 9)
        applied.fieldHandle = FieldHandle(pid: 100, token: 1, element: nil)
        fixture.publish(focus: applied)
        tapControlShift(fixture)  // must be #10: VI
        fixture.typeKeys([Key.a, Key.a])
        #expect(fixture.log.feeds == [.key(KeyInput("a")), .key(KeyInput("a"))])
        #expect(toggleSequences(fixture) == [1, 10])
    }
}

@Suite struct ReentryVerificationTests {
    /// PLT-R342: backspacing inside the word being typed is an ordinary recomposition (T2), never an AX read.
    @Test func backspaceInsideTheCurrentWordIsNotVerified() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.s])  // "á"
        fixture.completeJobs()
        fixture.press(Key.backspace)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.kind == .backspaceRecompose)
        #expect(!edit.verifyBeforeApply)
        #expect(edit.insertion == "a")
    }

    /// PLT-R342, ENG-R1002: Backspace over the boundary re-opens the committed word; edits of that word are
    /// re-entries the worker verifies when the rule allows it, until the word is committed again.
    @Test func editsOfAReopenedWordAreVerifiedReentries() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.space])
        #expect(fixture.press(Key.backspace) == .pass)  // removes the space, re-opens "a"
        fixture.press(Key.s)
        let accent = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(accent.kind == .reentry && accent.verifyBeforeApply)
        #expect(accent.replacedText == "a" && accent.insertion == "á")
        fixture.completeJobs()
        fixture.press(Key.backspace)  // removes the accent of the re-opened word
        let removal = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(removal.kind == .reentry && removal.verifyBeforeApply)
        fixture.completeJobs()
        fixture.typeKeys([Key.space, Key.a, Key.a])  // a new word: no longer a re-entry
        let next = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(next.kind == .compose && !next.verifyBeforeApply)
    }

    @Test func reentryIsNotVerifiedWhenTheRuleSaysNever() throws {
        let fixture = PipelineFixture(
            focus: PipelineFixtures.focus(decision: PipelineFixtures.decision(verifyReentry: .never)))
        fixture.typeKeys([Key.a, Key.space, Key.backspace, Key.s])
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.kind == .reentry && !edit.verifyBeforeApply)
    }

    /// A hard boundary drops the engine history, so the next word is fresh (ENG-R1011).
    @Test func aHardBoundaryEndsTheReentry() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.space, Key.backspace, Key.left, Key.a, Key.a])
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.kind == .compose && !edit.verifyBeforeApply)
    }
}

/// A recogniser that reports the combo on every keyDown of Space, autorepeat included: the pipeline itself
/// must ignore autorepeat (PRD-R14), whatever the recogniser does.
struct RepeatingComboRecognizer: HotkeyRecognizing {
    init(toggle: HotkeyBinding, restore: HotkeyBinding?) {}
    mutating func handle(_ input: HotkeyInput) -> HotkeyResult {
        if case .keyDown(let keyCode, _, _, _) = input, keyCode == KeyCode(rawValue: Key.space) { return .toggleCombo }
        return .none
    }
}

struct RepeatingComboFactory: CompositionEngineFactory, Sendable {
    typealias Hotkeys = RepeatingComboRecognizer
    let engines: ScriptedEngineFactory
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> ScriptedEngine {
        engines.makeEngine(for: variant, settings: settings)
    }
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot, continuing engine: ScriptedEngine)
        -> ScriptedEngine
    { engines.makeEngine(for: variant, settings: settings, continuing: engine) }
}

@Suite struct HotkeyHardeningTests {
    @Test func autorepeatOfAComboNeverTogglesAgainPRDR14() {
        let fixture = PipelineFixture()
        let pipeline = KeyPipeline(
            context: fixture.context, factory: RepeatingComboFactory(engines: ScriptedEngineFactory(log: fixture.log)),
            clock: fixture.clock)
        func send(_ kind: RawKeyEvent.Kind, autorepeat: Bool = false) -> TapVerdict {
            pipeline.handle(PipelineFixtures.keyEvent(kind, Key.space, flags: Flag.control, autorepeat: autorepeat))
        }
        #expect(send(.keyDown) == .swallow)
        for _ in 0..<3 {
            #expect(send(.keyDown, autorepeat: true) == .swallow)
            #expect(pipeline.lastOutcome == .consumedAsHotkey)
        }
        #expect(send(.keyUp) == .swallow)
        #expect(toggleSequences(fixture) == [1])
    }
}

@Suite struct LiveSettingsHardeningTests {
    /// PRD-R27, PLT-R340: a settings change that leaves the engines alone (same catalog revision) rebuilds the
    /// hotkeys only and keeps the word being typed.
    @Test func hotkeyRebindingMidWordKeepsTheWord() throws {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(engineRevision: 7))
        fixture.press(Key.a)
        let combo = HotkeyBinding.keyCombo(modifiers: [.control], keyCode: KeyCode(rawValue: Key.space))
        fixture.publish(settings: PipelineFixtures.settings(generation: 2, toggle: combo, engineRevision: 7))
        fixture.press(Key.a)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.insertion == "â")
        #expect(fixture.log.madeVariants.count == 1)
        #expect(fixture.log.resets.isEmpty)
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.space, flags: Flag.control) == .swallow)  // the new binding is live
        #expect(fixture.lastOutcome == .consumedAsHotkey)
    }

    /// PLT-R1008: a new revision (or an unknown one) builds a fresh engine at once.
    @Test(arguments: [UInt64?.some(8), nil])
    func aNewEngineRevisionBuildsAFreshEngine(revision: UInt64?) {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(engineRevision: 7))
        fixture.press(Key.a)
        fixture.publish(settings: PipelineFixtures.settings(generation: 2, engineRevision: revision))
        fixture.press(Key.a)
        #expect(fixture.log.madeVariants.count == 2)
        #expect(fixture.popJobs().isEmpty)  // the second "a" starts a new word
    }
}

@Suite struct DeadKeyHardeningTests {
    private func azerty(settings: TapSettingsSnapshot = PipelineFixtures.settings()) -> PipelineFixture {
        let source = PipelineFixtures.inputSource(table: PipelineFixtures.azertyTable())
        return PipelineFixture(settings: settings, inputSource: source)
    }

    /// PLT-R354: a reconciliation between the dead key and the next key (a worker reset here) does not
    /// forget that the next key belongs to the dead key.
    @Test func keyAfterADeadKeyPassesAcrossAReconciliation() {
        let fixture = azerty()
        #expect(fixture.press(Key.azertyDeadKey) == .pass)
        fixture.feedback.requestCompositionReset()
        #expect(fixture.press(Key.e) == .pass)
        #expect(fixture.log.feeds.isEmpty)
        fixture.press(Key.e)
        #expect(fixture.log.feeds == [.key(KeyInput("e"))])
    }

    /// PLT-R354 before PLT-R353: the restore binding pressed right after a dead key passes untouched.
    @Test func restoreBindingAfterADeadKeyPassesUntouched() {
        let fixture = azerty(settings: PipelineFixtures.settings(restore: .key(KeyCode(rawValue: Key.escape))))
        fixture.press(Key.azertyDeadKey)
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(!fixture.log.feeds.contains(.restoreToggle))
    }

    /// A pointer down ends the dead-key sequence (the click moves the caret).
    @Test func pointerDownEndsTheDeadKeySequence() {
        let fixture = azerty()
        fixture.press(Key.azertyDeadKey)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        fixture.press(Key.e)
        #expect(fixture.log.feeds == [.key(KeyInput("e"))])
    }
}

@Suite struct RestoreHardeningTests {
    /// PLT-R353, PLT-R312, ADR 0308: the restore key is a hotkey; if the worker abandons the restore, nothing
    /// is replayed (an Escape would close Spotlight or a dialog) and its keyUp stays consumed.
    @Test func abandonedRestoreNeverReplaysTheRestoreKey() throws {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: .key(KeyCode(rawValue: Key.escape))))
        fixture.typeKeys([Key.a, Key.a])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.escape) == .swallow)
        #expect(fixture.lastOutcome == .consumedAsHotkey)
        let jobs = fixture.completeJobs(outcome: .abandoned)
        let edit = try #require(jobs.compactMap(\.edit).first)
        #expect(edit.kind == .restore && edit.trigger == nil)
        #expect(!jobs.contains { $0.kind == .replay })
        #expect(fixture.keyUp(Key.escape) == .swallow)
        #expect(fixture.lastOutcome == .consumedPairedKeyUp)
    }
}

@Suite struct FieldTokenHardeningTests {
    private func focusWithoutToken(_ generation: UInt64) -> FocusSnapshot {
        var focus = PipelineFixtures.focus(generation: generation)
        focus.fieldHandle = nil
        return focus
    }

    /// PLT-R210, ENG-R1010: without a field token (AX unavailable or timed out) the pipeline cannot tell a
    /// republication from a new element of the same app, so every new focus generation resets.
    @Test func newGenerationWithoutAFieldTokenResets() {
        let fixture = PipelineFixture(focus: focusWithoutToken(1))
        fixture.press(Key.a)
        fixture.publish(focus: focusWithoutToken(2))
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.focusChanged])
        #expect(fixture.popJobs().isEmpty)
    }
}
