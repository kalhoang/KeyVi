// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tap's side of focus tracking after events that move the focus without an app activation (PLT-R389: a
// shortcut opens Spotlight or a save sheet, Escape closes Spotlight, a click, Return, Tab, an overlay rule) and the
// late focus change (PLT-R340 amendment of 2026-11-14, Pa's T5.5 report: Command+S, then `dduowngf` in the save
// sheet gave "ddường"). Driven with the pipeline doubles (PipelineFixture, ScriptedEngine).

import AppModel
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private func triggers(_ notices: [AXNotice]) -> Int {
    notices.filter { if case .revalidateFocusAfterTrigger = $0 { true } else { false } }.count
}

private func reads(_ notices: [AXNotice]) -> Int {
    notices.filter { if case .revalidateFocus = $0 { true } else { false } }.count
}

/// PLT-R389 reads that skip the attributes while the focused app and element are the published ones.
private func movedChecks(_ notices: [AXNotice]) -> Int {
    notices.filter { if case .revalidateFocusIfMoved = $0 { true } else { false } }.count
}

/// A fixture past its first key (which always revalidates, PLT-R382), so the counts below start at zero.
private func typingFixture(focus: FocusSnapshot = PipelineFixtures.focus()) -> (PipelineFixture, Int) {
    let fixture = PipelineFixture(focus: focus)
    fixture.press(Key.space)
    fixture.completeJobs()
    return (fixture, fixture.axNotices().count)
}

@Suite struct FocusTriggerTests {
    /// PLT-R389: Command+Space opens Spotlight, a non-activating panel: no activation notification comes, so the
    /// shortcut itself asks for the trigger settle window (Pa's items 7 and 9, 2026-11-14).
    @Test func aCommandShortcutAsksForTheTriggerWindowPLTR389() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.press(Key.space, flags: Flag.command)
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1 && reads(notices) == 0)
    }

    @Test func controlShortcutsEscapeReturnTabAndClicksAreTriggersPLTR389() {
        let (fixture, before) = typingFixture()
        for (key, flags) in [(Key.s, Flag.control), (Key.escape, 0), (Key.returnKey, 0), (Key.tab, 0)] {
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(key, flags: flags)
            fixture.completeJobs()
        }
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 5)
    }

    /// PLT-R389: the panel may take the focus after the last settle read; the first keyDown after the trigger asks
    /// for one more read, the keys after it do not (they are within the typing rhythm). That read only checks
    /// whether the focused app or element moved, so a Command+C in a document costs no attribute walk.
    @Test func theFirstKeyAfterATriggerReadsOnceMorePLTR389() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.press(Key.space, flags: Flag.command)
        for key in [Key.d, Key.d, Key.u] {
            fixture.clock.advance(byMicroseconds: 100_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1 && movedChecks(notices) == 1 && reads(notices) == 0)
        #expect(fixture.log.feeds.count == 4)  // the space of `typingFixture` and the three letters: nothing waits
    }

    /// PLT-R389: while an overlay rule applies (Spotlight, Raycast, Alfred), every keyDown asks for a read, so the
    /// keys after the panel closed (Escape, a click outside) use the previous app's rules at once.
    @Test func everyKeyReadsWhileAnOverlayRuleAppliesPLTR389() {
        var decision = PipelineFixtures.decision(restoreHotkeyEnabled: false)
        decision.overlay = true
        let (fixture, before) = typingFixture(focus: PipelineFixtures.focus(decision: decision))
        for key in [Key.d, Key.e, Key.x] {
            fixture.clock.advance(byMicroseconds: 80_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(movedChecks(notices) == 3 && reads(notices) == 0)
    }

    /// PLT-R382 keeps the full read: the first key after a pause may follow a change of the same element's
    /// attributes (a page navigated in the same web area), which a moved-only check would not see.
    @Test func aKeyAfterAPauseReadsInFullEvenAfterATriggerPLTR382() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.press(Key.space, flags: Flag.command)
        fixture.clock.advance(byMicroseconds: FocusRevalidation.idleNanoseconds / 1_000)
        fixture.press(Key.d)
        fixture.completeJobs()
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(reads(notices) == 1 && movedChecks(notices) == 0)
    }

    /// PLT-R389: the focus can move while English mode, a pause or a passThrough rule applies; the request does not
    /// depend on the engine being fed.
    @Test func triggersAskInEnglishModeAndWhilePausedPLTR389() {
        for focus in [
            PipelineFixtures.focus(mode: .english), PipelineFixtures.focus(pause: .noTextFocus),
            PipelineFixtures.focus(decision: PipelineFixtures.decision(strategy: .passThrough)),
        ] {
            let (fixture, before) = typingFixture(focus: focus)
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(Key.space, flags: Flag.command)
            #expect(triggers(Array(fixture.axNotices().dropFirst(before))) == 1)
            #expect(fixture.log.feeds.isEmpty)
        }
    }

    @Test func autorepeatAndOrdinaryKeysAreNoTriggers() {
        let (fixture, before) = typingFixture()
        fixture.clock.advance(byMicroseconds: 50_000)
        fixture.keyDown(Key.returnKey)
        fixture.clock.advance(byMicroseconds: 30_000)
        fixture.keyDown(Key.returnKey, autorepeat: true)
        fixture.keyUp(Key.returnKey)
        fixture.completeJobs()
        for key in [Key.a, Key.left, Key.backspace, Key.f5] {
            fixture.clock.advance(byMicroseconds: 50_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        let notices = Array(fixture.axNotices().dropFirst(before))
        #expect(triggers(notices) == 1)
        #expect(movedChecks(notices) == 1)  // the "a": an autorepeat is not the next key
    }
}

@Suite struct LateFocusChangeTests {
    /// The token's last key at `fixture.clock.now()`; a new element of `pid` observed `after` microseconds later.
    private func publishNewElement(
        _ fixture: PipelineFixture, generation: UInt64 = 2, pid: Int32 = 100, after microseconds: UInt64 = 50_000,
        change: (inout FocusSnapshot) -> Void = { _ in }
    ) {
        var focus = PipelineFixtures.focus(
            generation: generation, pid: pid, changedAt: fixture.clock.now().advanced(byMicroseconds: microseconds))
        change(&focus)
        fixture.publish(focus: focus)
        fixture.clock.advance(byMicroseconds: microseconds + 30_000)
    }

    /// Pa's T5.5 (2026-11-14): the first key went into the sheet's field while the snapshot still named the
    /// document; the field change is discovered on the second key. Same process, readable element, observed right
    /// after the token's last key: the composition is kept and the first job verifies the field.
    @Test func aLateFocusChangeInTheSameProcessKeepsTheCompositionPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        publishNewElement(fixture)
        fixture.press(Key.a)  // still the same word: "aa" -> "â"
        #expect(fixture.log.resets.isEmpty)
        let jobs = fixture.popJobs()
        let edit = try #require(jobs.compactMap(\.edit).first)
        #expect(edit.insertion == "â" && edit.verifyLateFocus && edit.replacedText == "a")
        #expect(edit.generation == FocusGeneration(rawValue: 2))
        #expect(!jobs.contains { $0.boundaryReason != nil })
        fixture.completeJobs()
        fixture.press(Key.s)
        #expect(fixture.popJobs().compactMap(\.edit).first?.verifyLateFocus == false)  // only the first job checks
    }

    /// The key that discovers the change may produce no edit: a job without an edit carries the check and the key
    /// is held behind it, so a field that does not match resets the composition at once.
    @Test func aKeyWithoutAnEditCarriesTheCheckPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        publishNewElement(fixture)
        #expect(fixture.keyDown(Key.d) == .swallow)
        #expect(fixture.lastOutcome == .held)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay])
        let check = try #require(jobs.first?.edit)
        #expect(check.verifyLateFocus && check.deleteCount == 0 && check.insertion.isEmpty && check.trigger == nil)
        #expect(check.replacedText == "a")
        #expect(fixture.log.resets.isEmpty)
    }

    @Test func anotherProcessIsAHardBoundaryPLTR340() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        publishNewElement(fixture, pid: 300)
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.applicationChanged])
        #expect(fixture.popJobs().compactMap(\.edit).isEmpty)  // "a" starts a new word
    }

    /// Retest of 15/11/2026, item 24 (Dokomo): `duw` shows "dư", Command+Tab to another app and back, then two
    /// keys. The Command chord and the return through another process both end the word (PLT-R340; the late focus
    /// exception needs the same process within 500 ms), so the keys start a new word: `x a` pass as typed and give
    /// "dưxa" on screen, `a s` compose "á" from their own keys only. No job ever deletes into the old word.
    @Test(arguments: [([Key.x, Key.a], 0), ([Key.a, Key.s], 1)])
    func aCommandTabRoundTripEndsTheWordPLTR340(keys: [UInt16], edits: Int) throws {
        let fixture = PipelineFixture()
        for key in [Key.d, Key.u, Key.w] {
            fixture.clock.advance(byMicroseconds: 120_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        _ = fixture.popJobs()
        fixture.clock.advance(byMicroseconds: 300_000)
        fixture.flags(Key.command, Flag.command)
        fixture.press(Key.tab, flags: Flag.command)  // Command+Tab: a Command chord
        fixture.flags(Key.command, 0)
        publishNewElement(fixture, generation: 2, pid: 300, after: 130_000)  // the other app
        fixture.clock.advance(byMicroseconds: 400_000)
        publishNewElement(fixture, generation: 3, pid: 100, after: 90_000)  // back to the same field's app
        fixture.clock.advance(byMicroseconds: 600_000)
        var verdicts: [TapVerdict] = []
        for key in keys {
            verdicts.append(fixture.keyDown(key))
            fixture.keyUp(key)
            fixture.clock.advance(byMicroseconds: 400_000)
        }
        let jobs = fixture.popJobs().compactMap(\.edit)
        #expect(fixture.log.resets.first == .shortcut)
        #expect(jobs.count == edits)
        #expect(jobs.allSatisfy { $0.deleteCount <= 1 && !$0.verifyLateFocus })
        if edits == 0 { #expect(verdicts.allSatisfy { $0 == .pass }) }
        if edits == 1 { #expect(jobs.first?.insertion == "á" && jobs.first?.deleteCount == 1) }
    }

    /// A snapshot whose system-wide focus read timed out names no app (Pa's Safari trace, 15/11/2026). The first
    /// real snapshot of the app right after it is not an application change: the composition is kept and the first
    /// job verifies the field (PLT-R340 amendment of 2026-11-15).
    private func publishTimedOutSnapshot(_ fixture: PipelineFixture, generation: UInt64 = 2, timedOut: Bool = true) {
        var focus = PipelineFixtures.focus(generation: generation, changedAt: fixture.clock.now())
        focus.app = nil
        focus.fieldHandle = nil
        focus.field.axAvailability = timedOut ? .timedOut : .available
        fixture.publish(focus: focus)
    }

    @Test func aRealSnapshotAfterATimedOutReadKeepsTheCompositionPLTR340() throws {
        let fixture = PipelineFixture()
        publishTimedOutSnapshot(fixture)
        fixture.press(Key.a)  // composed on the app-less snapshot (its boundary found a clean engine)
        publishNewElement(fixture, generation: 3)
        fixture.press(Key.a)  // "aa" -> "â" in the same word
        #expect(fixture.log.resets.isEmpty)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.insertion == "â" && edit.verifyLateFocus && edit.replacedText == "a")
    }

    /// An app-less snapshot that did not time out (AX answered: no focused application) is a real change.
    @Test func anAppLessSnapshotThatDidNotTimeOutIsAHardBoundaryPLTR340() {
        let fixture = PipelineFixture()
        publishTimedOutSnapshot(fixture, timedOut: false)
        fixture.press(Key.a)
        publishNewElement(fixture, generation: 3)
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.applicationChanged])
        #expect(fixture.popJobs().compactMap(\.edit).isEmpty)
    }

    /// The window and the readable-element conditions still apply after a timed-out read.
    @Test func aTimedOutReadDoesNotWidenTheOtherConditionsPLTR340() {
        let late = PipelineFixture()
        publishTimedOutSnapshot(late)
        late.press(Key.a)
        publishNewElement(late, generation: 3, after: 600_000)
        late.press(Key.a)
        #expect(late.log.resets == [.applicationChanged])

        let unreadable = PipelineFixture()
        publishTimedOutSnapshot(unreadable)
        unreadable.press(Key.a)
        publishNewElement(unreadable, generation: 3) { $0.field.axAvailability = .timedOut }
        unreadable.press(Key.a)
        #expect(unreadable.log.resets == [.applicationChanged])
    }

    /// PLT-R381 amendment (2026-11-15): when AX names no app the snapshot takes NSWorkspace's frontmost application,
    /// without an element or field handle.
    private func publishFrontmostSnapshot(_ fixture: PipelineFixture, generation: UInt64 = 2, pid: Int32 = 100) {
        var focus = PipelineFixtures.focus(generation: generation, pid: pid, changedAt: fixture.clock.now())
        focus.app?.source = .frontmostApplication
        focus.fieldHandle = nil
        focus.field = FieldContext(
            axAvailability: .available, role: nil, subrole: nil, identifier: nil, domClasses: [], editable: nil,
            secure: false)
        fixture.publish(focus: focus)
    }

    /// AX then names the same process with a readable field: the field belongs to the process the word was typed
    /// in, so the late focus change keeps the word and the first job verifies the field.
    @Test func theSameProcessAfterTheFrontmostFallbackKeepsTheCompositionPLTR340() throws {
        let fixture = PipelineFixture()
        publishFrontmostSnapshot(fixture)
        fixture.press(Key.a)
        publishNewElement(fixture, generation: 3)
        fixture.press(Key.a)
        #expect(fixture.log.resets.isEmpty)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.insertion == "â" && edit.verifyLateFocus && edit.replacedText == "a")
    }

    /// The weaker identity does not widen the rule the way a timed-out read does: another process is an
    /// application change, and so is a late observation.
    @Test func anotherProcessAfterTheFrontmostFallbackIsAHardBoundaryPLTR340() {
        let other = PipelineFixture()
        publishFrontmostSnapshot(other)
        other.press(Key.a)
        publishNewElement(other, generation: 3, pid: 300)
        other.press(Key.a)
        #expect(other.log.resets == [.applicationChanged])
        #expect(other.popJobs().compactMap(\.edit).isEmpty)

        let late = PipelineFixture()
        publishFrontmostSnapshot(late)
        late.press(Key.a)
        publishNewElement(late, generation: 3, after: 600_000)
        late.press(Key.a)
        #expect(late.log.resets == [.focusChanged])
    }

    /// 500 ms after the token's last key the change is no longer part of the word being typed.
    @Test func aChangeObservedTooLateIsAHardBoundaryPLTR340() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        publishNewElement(fixture, after: 600_000)
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.focusChanged])
        let atTheLimit = PipelineFixture()
        atTheLimit.press(Key.a)
        publishNewElement(atTheLimit, after: 500_000)
        atTheLimit.press(Key.a)
        #expect(atTheLimit.log.resets.isEmpty)
    }

    /// The worker could not read the new element (no AX element, AX unavailable or timed out): hard boundary.
    @Test func anUnreadableElementIsAHardBoundaryPLTR340() {
        let changes: [(inout FocusSnapshot) -> Void] = [
            { $0.fieldHandle = nil }, { $0.field.axAvailability = .unavailable },
            { $0.field.axAvailability = .timedOut },
        ]
        for change in changes {
            let fixture = PipelineFixture()
            fixture.press(Key.a)
            publishNewElement(fixture, change: change)
            fixture.press(Key.a)
            #expect(fixture.log.resets == [.focusChanged])
        }
    }

    /// No word in progress (a separator committed it), a new engine variant or a focus pause: hard boundary.
    @Test func noActiveTokenAnotherVariantOrAPauseIsAHardBoundaryPLTR340() {
        let committed = PipelineFixture()
        committed.typeKeys([Key.a, Key.space])
        publishNewElement(committed)
        committed.press(Key.a)
        #expect(committed.log.resets == [.focusChanged])

        let variant = PipelineFixture()
        variant.press(Key.a)
        let code = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        publishNewElement(variant) { $0.decision = PipelineFixtures.decision(variant: code) }
        variant.press(Key.a)
        #expect(variant.log.madeVariants == [.default, code])

        let paused = PipelineFixture()
        paused.press(Key.a)
        publishNewElement(paused) { $0.pause = .noTextFocus }
        paused.press(Key.a)
        #expect(paused.log.resets.first == .focusChanged)
    }

    /// Until the kept composition is verified, the restore key passes untouched (an Escape may close the sheet) and
    /// is a hard boundary as usual (PLT-R353).
    @Test func theRestoreKeyPassesUntilTheLateChangeIsVerifiedPLTR340() {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: .key(.escape)))
        fixture.typeKeys([Key.a, Key.s])  // "á"
        fixture.completeJobs()
        publishNewElement(fixture)
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(fixture.log.feeds.allSatisfy { if case .restoreToggle = $0 { false } else { true } })
        #expect(fixture.log.resets == [.shortcut])
    }

    /// A worker that found the field different resets the composition before the next key (ADR 0308).
    @Test func aFailedCheckResetsBeforeTheNextKeyPLTR340() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        publishNewElement(fixture)
        fixture.press(Key.a)
        fixture.completeJobs(outcome: .passedThroughByFallback)
        fixture.feedback.requestCompositionReset()
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.unknown])
        #expect(fixture.popJobs().compactMap(\.edit).isEmpty)  // the next "a" starts a new word
    }
}
