// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W1-F1 step acceptance: PLT-R310 steps one key at a time against the real seams and the scripted engine.

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct KeyPipelineComposeTests {
    @Test func plainKeyPassesAndIsFedToTheEngine() {
        let fixture = PipelineFixture()
        #expect(fixture.keyDown(Key.a) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
        #expect(fixture.keyUp(Key.a) == .pass)
        #expect(fixture.popJobs().isEmpty)
    }

    /// PLT-R310 steps 8 to 10, PLT-R401: an edit swallows the key and carries what the worker needs.
    @Test func editSwallowsTheTriggerAndPushesAnEditJob() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.a) == .swallow)
        #expect(fixture.lastOutcome == .consumedForEdit)
        let job = try #require(fixture.popJobs().first?.edit)
        #expect(job.deleteCount == 1)
        #expect(job.deleteUTF16Count == 1)
        #expect(job.insertion == "â")
        #expect(job.replacedText == "a")
        #expect(job.kind == .compose)
        #expect(job.trigger?.keyCode == KeyCode(rawValue: Key.a))
        #expect(job.keyCodes.trigger == KeyCode(rawValue: Key.a))
        #expect(job.keyCodes.firstCharacter == nil)
        #expect(job.keyCodes.paste == KeyCode(rawValue: 0x09))  // "v" in the layout (PLT-R461)
        #expect(job.generation == FocusGeneration(rawValue: 1))
        #expect(job.plan == .init(strategy: .backspaceReplace, parameters: .defaults, fallback: [.passThrough]))
    }

    /// PLT-R313 with ADR 0308: the keyUp of a consumed keyDown follows its job's outcome.
    @Test func keyUpOfAConsumedKeyFollowsTheJobOutcome() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        let edit = try #require(fixture.popJobs().first?.edit)
        // Still queued: a pairedKeyUp the worker resolves.
        #expect(fixture.keyUp(Key.a) == .swallow)
        #expect(fixture.lastOutcome == .consumedPairedKeyUp)
        let paired = fixture.popJobs()
        guard case .pairedKeyUp(_, let record, let forJob)? = paired.first else {
            Issue.record("expected a pairedKeyUp, got \(paired)")
            return
        }
        #expect(forJob == edit.sequence)
        #expect(record.kind == .keyUp)
    }

    @Test func keyUpAfterAnExecutedEditIsConsumedWithoutAJob() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        fixture.completeJobs(outcome: .executed)
        #expect(fixture.keyUp(Key.a) == .swallow)
        #expect(fixture.lastOutcome == .consumedPairedKeyUp)
        #expect(fixture.popJobs().isEmpty)
    }

    @Test(arguments: [JobOutcome.abandoned, .discardedForGeneration, .passedThroughByFallback])
    func keyUpAfterAReplayedTriggerPasses(outcome: JobOutcome) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        fixture.completeJobs(outcome: outcome)
        #expect(fixture.keyUp(Key.a) == .pass)
        #expect(fixture.lastOutcome == .passed)
    }

    /// PLT-R311: while a job is in flight every event the pipeline would pass is held, in order.
    @Test func eventsAreHeldWhileAJobIsInFlight() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit, in flight
        #expect(fixture.keyDown(Key.d) == .swallow)
        #expect(fixture.lastOutcome == .held)
        #expect(fixture.flags(Key.shift, Flag.shift) == .swallow)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay, .replay])
        #expect(jobs[1].replayed?.keyCode == KeyCode(rawValue: Key.d))
        #expect(jobs[2].replayed?.kind == .flagsChanged)
        for job in jobs { fixture.queue.finished(PipelineFixture.sequence(of: job), expectation: nil) }
        #expect(fixture.keyUp(Key.d) == .pass)
    }

    /// PLT-R341: space is a soft boundary fed to the engine as a key, not a reset.
    @Test func spaceIsFedAsAKey() {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.space])
        #expect(fixture.log.feeds == [.key(KeyInput("a")), .key(KeyInput(" "))])
        #expect(fixture.log.resets.isEmpty)
    }

    /// PLT-R361: the engine receives what the layout produces, not what the key position means on QWERTY.
    @Test func charactersComeFromTheLayoutTable() {
        let fixture = PipelineFixture(inputSource: PipelineFixtures.inputSource(table: PipelineFixtures.azertyTable()))
        fixture.press(0x0C)  // the AZERTY "a" key sits where QWERTY has "q"
        fixture.press(0x12, flags: Flag.shift)  // AZERTY digits need Shift
        #expect(fixture.log.feeds == [.key(KeyInput("a")), .key(KeyInput("1"))])
    }

    @Test func capsLockAndShiftSelectTheUppercaseColumn() {
        let fixture = PipelineFixture()
        fixture.press(Key.a, flags: Flag.capsLock)
        fixture.press(Key.s, flags: Flag.shift)
        #expect(fixture.log.feeds == [.key(KeyInput("A")), .key(KeyInput("S"))])
    }
}

@Suite struct KeyPipelineBoundaryStepTests {
    /// P0-3, ADR 0306 decision 3: Return and Tab are fed before the hard boundary.
    @Test(arguments: [(Key.returnKey, Character("\n")), (Key.tab, Character("\t")), (Key.keypadEnter, Character("\n"))])
    func returnAndTabAreFedBeforeTheHardBoundary(key: UInt16, character: Character) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(key) == .pass)
        let events = fixture.log.events
        #expect(events.suffix(2) == [.key(KeyInput(character)), .reset(.cursorMoved)])
    }

    /// P0-3: a restored word reaches the app before the Return that ended it.
    @Test func returnAfterARestoredTokenIsReplayedAfterTheCorrection() throws {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.x, Key.s])  // "áx" displayed, raw "axs", marked English
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.returnKey) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay, .boundary])
        let edit = try #require(jobs[0].edit)
        #expect(edit.insertion == "axs")
        #expect(edit.trigger == nil)  // the key itself is the replay (ADR 0308)
        #expect(jobs[1].replayed?.keyCode == KeyCode(rawValue: Key.returnKey))
        #expect(jobs[2].boundaryReason == .returnOrTab)
        for job in jobs { fixture.queue.finished(PipelineFixture.sequence(of: job), expectation: nil) }
        #expect(fixture.keyUp(Key.returnKey) == .pass)  // its keyDown was delivered, so is its keyUp
    }

    /// PLT-R340: passed Escape is a hard boundary.
    @Test func escapePassedIsAHardBoundary() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(fixture.log.resets == [.shortcut])
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
    }

    /// PLT-R355: keypad digits reach the engine flagged, so they are never VNI tone keys by default.
    @Test func keypadDigitsAreFlagged() {
        let fixture = PipelineFixture()
        fixture.press(Key.keypad1)
        fixture.press(0x12)
        #expect(fixture.log.feeds == [.key(KeyInput("1", fromKeypad: true)), .key(KeyInput("1", fromKeypad: false))])
    }

    /// PLT-R356: navigation never edits, even with jobs in flight; it is a hard boundary.
    @Test(arguments: [Key.left, Key.up, Key.down, 0x73, 0x77, 0x74, 0x79])
    func navigationNeverEdits(key: UInt16) {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.u])
        #expect(fixture.press(key) == .pass)
        fixture.press(Key.w)  // after the boundary "w" types "ư" alone, it no longer modifies the "u"
        let edit = fixture.popJobs().compactMap(\.edit).first
        #expect(edit?.deleteCount == 0)
        #expect(fixture.log.resets == [.cursorMoved])
        #expect(!fixture.log.feeds.contains(.backspace))
    }

    @Test func forwardDeleteIsABoundary() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.press(Key.forwardDelete) == .pass)
        #expect(fixture.log.resets == [.forwardDelete])
    }

    /// PLT-R350: Command or Control chords and Option characters pass and are hard boundaries.
    @Test(arguments: [Flag.command, Flag.control, Flag.option])
    func chordsPassAndReset(flags: UInt64) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.a, flags: flags) == .pass)
        #expect(fixture.log.resets == [.shortcut])
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
    }

    @Test func optionBackspaceDeletesAWordAndIsNavigation() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.backspace, flags: Flag.option) == .pass)
        #expect(fixture.log.resets == [.cursorMoved])
    }

    @Test func functionKeysPassAndReset() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.press(Key.f5) == .pass)
        #expect(fixture.log.resets == [.unknown])
    }

    /// PLT-R351: character autorepeat passes untransformed and ends the composition; backspace repeats are fed
    /// one by one; navigation repeats pass.
    @Test func autorepeatRules() {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.a)
        #expect(fixture.keyDown(Key.a, autorepeat: true) == .pass)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
        #expect(fixture.log.resets == [.unknown])
        fixture.keyUp(Key.a)
        fixture.press(Key.d)
        fixture.press(Key.e)
        fixture.keyDown(Key.backspace)
        fixture.keyDown(Key.backspace, autorepeat: true)
        fixture.keyDown(Key.backspace, autorepeat: true)
        #expect(fixture.log.feeds.filter { $0 == .backspace }.count == 3)
        #expect(fixture.keyDown(Key.left, autorepeat: true) == .pass)
    }

    /// PLT-R354: a dead key and the key after it pass untouched, with a hard boundary.
    @Test func deadKeysPassWithTheFollowingKey() {
        let fixture = PipelineFixture(inputSource: PipelineFixtures.inputSource(table: PipelineFixtures.azertyTable()))
        fixture.press(Key.e)
        #expect(fixture.press(Key.azertyDeadKey) == .pass)
        #expect(fixture.press(Key.e) == .pass)
        #expect(fixture.log.feeds == [.key(KeyInput("e"))])
        fixture.press(Key.e)  // the key after that is composed again
        #expect(fixture.log.feeds == [.key(KeyInput("e")), .key(KeyInput("e"))])
    }

    @Test func unmappedKeysPassWithoutFeeding() {
        let fixture = PipelineFixture(inputSource: PipelineFixtures.inputSource(table: PipelineFixtures.azertyTable()))
        #expect(fixture.press(0x03) == .pass)  // not in the AZERTY subset
        #expect(fixture.log.feeds.isEmpty)
    }

    /// PLT-R317, PLT-R340: a mouse down is a boundary, never held, and marks the boundary in FIFO order.
    @Test func mouseDownIsNeverHeldAndMarksABoundary() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight
        #expect(fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0)) == .pass)
        #expect(fixture.lastOutcome == nil)
        #expect(fixture.popJobs().map(\.boundaryReason) == [nil, .mouseDown])
        #expect(fixture.log.resets == [.pointerClicked])
        #expect(fixture.send(PipelineFixtures.keyEvent(.rightMouseDown, 0)) == .pass)
        #expect(fixture.send(PipelineFixtures.keyEvent(.otherMouseDown, 0)) == .pass)
    }
}

@Suite struct KeyPipelineHotkeyStepTests {
    private static let pressControl = (Key.control, Flag.control)
    private static let pressShift = (Key.shift, Flag.control | Flag.shift)
    private static let releaseShift = (Key.shift, Flag.control)
    private static let releaseControl = (Key.control, UInt64(0))

    private func tapControlShift(_ fixture: PipelineFixture, scrollInBetween: Bool = false) {
        fixture.flags(Self.pressControl.0, Self.pressControl.1)
        fixture.flags(Self.pressShift.0, Self.pressShift.1)
        if scrollInBetween {
            #expect(fixture.send(PipelineFixtures.keyEvent(.scrollWheel, 0, flags: Flag.control | Flag.shift)) == .pass)
            #expect(fixture.lastOutcome == nil)
        }
        fixture.flags(Self.releaseShift.0, Self.releaseShift.1)
        fixture.flags(Self.releaseControl.0, Self.releaseControl.1)
    }

    /// PRD-R14, D11: tap Control+Shift toggles on release; the modifier events themselves pass.
    @Test func controlShiftTapTogglesTheMode() {
        let fixture = PipelineFixture()
        tapControlShift(fixture)
        #expect(fixture.mainNotices().compactMap(\.toggledMode) == [.english])
        #expect(fixture.axNotices().count == 1)
        fixture.press(Key.a)
        fixture.press(Key.a)
        #expect(fixture.log.feeds.isEmpty)  // EN mode: nothing reaches the engine
    }

    /// PRD-R14, PLT-R301: a scroll between press and release cancels the toggle and is passed unchanged.
    @Test func scrollBetweenPressAndReleaseCancelsTheToggle() {
        let fixture = PipelineFixture()
        tapControlShift(fixture, scrollInBetween: true)
        #expect(fixture.mainNotices().isEmpty)
    }

    @Test func mouseDownBetweenPressAndReleaseCancelsTheToggle() {
        let fixture = PipelineFixture()
        fixture.flags(Self.pressControl.0, Self.pressControl.1)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        fixture.flags(Self.releaseControl.0, Self.releaseControl.1)
        #expect(fixture.mainNotices().isEmpty)
    }

    /// PRD-R15: while the app's own recorder captures keys, hotkeys are suspended.
    @Test func recorderSuspendsHotkeys() {
        let fixture = PipelineFixture(lifecycle: PipelineFixtures.lifecycle(recorderActive: true))
        tapControlShift(fixture)
        #expect(fixture.mainNotices().isEmpty)
    }

    /// Contracts 10.2: a key combo consumes its keyDown, autorepeat and keyUp.
    @Test func keyComboTogglesAndIsConsumed() {
        let combo = HotkeyBinding.keyCombo(modifiers: [.control], keyCode: KeyCode(rawValue: Key.space))
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(toggle: combo))
        #expect(fixture.keyDown(Key.space, flags: Flag.control) == .swallow)
        #expect(fixture.lastOutcome == .consumedAsHotkey)
        #expect(fixture.keyDown(Key.space, flags: Flag.control, autorepeat: true) == .swallow)
        #expect(fixture.keyUp(Key.space, flags: Flag.control) == .swallow)
        #expect(fixture.lastOutcome == .consumedPairedKeyUp)
        #expect(fixture.mainNotices().compactMap(\.toggledMode) == [.english])
        #expect(fixture.popJobs().isEmpty)
    }

    /// PLT-R353, ENG-R701, ENG-R702: the restore binding is consumed once and passed on the second press.
    @Test func restoreHotkeyConsumedOnceAndPassedOnTheSecondPress() throws {
        let restore = HotkeyBinding.key(KeyCode(rawValue: Key.escape))
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: restore))
        fixture.typeKeys([Key.a, Key.a])  // "â"
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.escape) == .swallow)
        #expect(fixture.lastOutcome == .consumedAsHotkey)  // a hotkey: never replayed (PLT-R353)
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.kind == .restore)
        #expect(edit.insertion == "aa")
        #expect(edit.keyCodes.firstCharacter == KeyCode(rawValue: Key.a))  // PLT-R405
        #expect(fixture.log.resets.isEmpty)  // a consumed Escape is not a boundary
        fixture.queue.finished(edit.sequence, expectation: nil)
        fixture.feedback.record(.executed, for: edit.sequence)
        #expect(fixture.keyUp(Key.escape) == .swallow)
        #expect(fixture.keyDown(Key.escape) == .pass)  // second press: nothing to restore
        #expect(fixture.log.resets == [.shortcut])  // the passed Escape is a hard boundary
    }

    @Test func restoreHotkeyRespectsTheRuleFeature() {
        let restore = HotkeyBinding.key(KeyCode(rawValue: Key.escape))
        let fixture = PipelineFixture(
            settings: PipelineFixtures.settings(restore: restore),
            focus: PipelineFixtures.focus(decision: PipelineFixtures.decision(restoreHotkeyEnabled: false)))
        fixture.typeKeys([Key.a, Key.a])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(!fixture.log.feeds.contains(.restoreToggle))
    }

    /// PLT-R353: with nothing to restore the bound key passes as if unbound; a function key is a boundary.
    @Test func restoreWithNothingToRestorePassesAnyBoundKey() {
        let restore = HotkeyBinding.key(KeyCode(rawValue: Key.f5))
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: restore))
        #expect(fixture.keyDown(Key.f5) == .pass)
        #expect(fixture.log.feeds == [.restoreToggle])
        #expect(fixture.log.resets == [.unknown])
    }

    /// PLT-R353: a character key bound to restore that passes types its character; the engine is fed, so the
    /// next edit does not delete the character it never saw.
    @Test func restoreBoundToACharacterKeyThatPassesKeepsTheEngineInSync() {
        let restore = HotkeyBinding.key(KeyCode(rawValue: Key.d))
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: restore))
        fixture.press(Key.a)
        #expect(fixture.keyDown(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
        fixture.keyUp(Key.d)
        fixture.press(Key.a)
        #expect(fixture.popJobs().isEmpty, "no edit: the engine saw \"ad\", not \"a\"")
        #expect(fixture.log.feeds == [.key(KeyInput("a")), .restoreToggle, .key(KeyInput("d")), .key(KeyInput("a"))])
    }

    /// PLT-R353, PLT-R340: a Command chord bound to restore that passes is still a hard boundary while the app
    /// runs its shortcut.
    @Test func restoreBoundToACommandChordThatPassesIsAHardBoundary() {
        let restore = HotkeyBinding.keyCombo(modifiers: .command, keyCode: KeyCode(rawValue: Key.d))
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: restore))
        fixture.press(Key.a)
        fixture.flags(Key.command, Flag.command)
        #expect(fixture.keyDown(Key.d, flags: Flag.command) == .pass)
        #expect(fixture.log.resets == [.shortcut])
    }

    /// PRD-R21: in an ignored app the toggle does nothing.
    @Test func toggleDoesNothingInAnIgnoredApp() throws {
        let rule = try #require(RuleID(rawValue: "user.ignore"))
        let fixture = PipelineFixture(focus: PipelineFixtures.focus(pause: .passThroughRule(rule)))
        tapControlShift(fixture)
        #expect(fixture.mainNotices().isEmpty)
    }

    @Test func rightCommandTapTogglesWithTheRightKeyOnly() {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(toggle: .modifierTap(.rightCommand)))
        fixture.flags(Key.rightCommand, Flag.command | Flag.rightCommandDevice)
        fixture.flags(Key.rightCommand, 0)
        #expect(fixture.mainNotices().compactMap(\.toggledMode) == [.english])
        fixture.flags(Key.command, Flag.command | 0x08)  // left Command
        fixture.flags(Key.command, 0)
        #expect(fixture.mainNotices().count == 1)
    }
}
