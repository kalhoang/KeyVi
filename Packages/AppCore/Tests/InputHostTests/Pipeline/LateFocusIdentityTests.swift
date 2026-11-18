// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R340 amendment of 19/11/2026 (VM runs of 19/11/2026 at 28aaa256, integration-suite.md section 10.9): one
// "last known element" rule for the tap. The same element is not a focus change, even with a snapshot without a
// readable element in between (`testhost.native.burst`); a snapshot of the same process without a readable element
// does not end the word being typed, and the next snapshot with a readable element is judged against the element
// the word began in (`testhost.sheet.commandS`); a word typed right after a focus-moving trigger (PLT-R389) is not
// measured from its first key. Every refusal by the keep checks leaves a reason code (PLT-R901: integers only).

import AppModel
import Diagnostics
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct LateFocusIdentityTests {
    /// A snapshot of the fixture's app (pid 100) observed `after` microseconds from now; the clock then moves past it.
    /// `PipelineFixtures.focus` names the element by its generation (token = generation) unless `change` says
    /// otherwise.
    private func publish(
        _ fixture: PipelineFixture, generation: UInt64, pid: Int32 = 100, after microseconds: UInt64 = 50_000,
        change: (inout FocusSnapshot) -> Void = { _ in }
    ) {
        var focus = PipelineFixtures.focus(
            generation: generation, pid: pid, changedAt: fixture.clock.now().advanced(byMicroseconds: microseconds))
        change(&focus)
        fixture.publish(focus: focus)
        fixture.clock.advance(byMicroseconds: microseconds + 30_000)
    }

    /// The same process without a readable element: its element read timed out (no field handle).
    private static func timedOutRead(_ focus: inout FocusSnapshot) {
        focus.fieldHandle = nil
        focus.field.axAvailability = .timedOut
    }

    /// The fixture's first element (generation 1) again.
    private static func firstElement(_ focus: inout FocusSnapshot) {
        focus.fieldHandle = FieldHandle(pid: 100, token: 1, element: nil)
    }

    private func typeWord(_ fixture: PipelineFixture, _ keys: [UInt16], every microseconds: UInt64 = 110_000) {
        for key in keys {
            fixture.press(key)
            fixture.completeJobs()
            fixture.clock.advance(byMicroseconds: microseconds)
        }
    }

    private func lateFocusRecords(_ fixture: PipelineFixture) -> [TapLogRecord] {
        var records: [TapLogRecord] = []
        fixture.tapLog.drain { if $0.code == .lateFocusKept || $0.code == .lateFocusRefused { records.append($0) } }
        return records
    }

    private func checks(_ jobs: [InjectionJob]) -> Int { jobs.filter { $0.edit?.verifyLateFocus == true }.count }

    // MARK: Item 1: the same element is not a focus change

    /// VM run 20261118T220253Z (`native.burst`, `nguyeẽn`): a timed-out notification read published a snapshot
    /// without the field before typing; the first key's read found the same field, which the ax thread now publishes
    /// with its token. No boundary and no check (the check of a field the app had not caught up with failed).
    @Test func theSameElementAgainAfterAnUnreadableSnapshotIsNoFocusChangePLTR340() {
        let fixture = PipelineFixture()  // generation 1, token 1
        publish(fixture, generation: 2, after: 0, change: Self.timedOutRead)
        fixture.press(Key.n)
        publish(fixture, generation: 3, after: 650, change: Self.firstElement)
        fixture.press(Key.g)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 0)
        #expect(lateFocusRecords(fixture).map(\.detail) == [LateFocusReason.sameElement.rawValue])
    }

    /// The same for a word that the unreadable snapshot kept: the element the word began in comes back.
    @Test func theElementTheWordBeganInComesBackAfterAnUnreadableSnapshotPLTR340() {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.d, Key.u])
        publish(fixture, generation: 2, after: 20_000, change: Self.timedOutRead)
        fixture.press(Key.w)
        publish(fixture, generation: 3, after: 20_000, change: Self.firstElement)
        fixture.press(Key.s)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 0)
    }

    /// A timed-out read resolves the rules without the field's attributes, so its decision may differ (a bundle-level
    /// strategy instead of the field's). The element found again is compared with its own last decision: no
    /// rule-change boundary either.
    @Test func theElementFoundAgainIsComparedWithItsOwnDecisionPLTR340() {
        let fixture = PipelineFixture()
        publish(fixture, generation: 2, after: 0) { focus in
            Self.timedOutRead(&focus)
            focus.decision = PipelineFixtures.decision(strategy: .selectReplace)
        }
        fixture.press(Key.a)
        publish(fixture, generation: 3, change: Self.firstElement)
        fixture.press(Key.a)
        #expect(fixture.log.resets.isEmpty)
        #expect(fixture.popJobs().compactMap(\.edit).map(\.insertion) == ["â"])
    }

    /// The engine took the unreadable snapshot's variant (a clean engine is rebuilt freely). Back in the element, the
    /// word continues when only `lookaheadRevision` differs (ENG-R1211 amendment), and any other variant change ends
    /// it with the boundary that says so, never by a silent rebuild.
    @Test func theElementFoundAgainWithAnotherVariantContinuesOrEndsTheWordPLTR340() {
        var panel = EngineVariant.default
        panel.lookaheadRevision = false
        let code = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        for (variant, continues) in [(panel, true), (code, false)] {
            let fixture = PipelineFixture()
            publish(fixture, generation: 2, after: 0) { focus in
                Self.timedOutRead(&focus)
                focus.decision = PipelineFixtures.decision(variant: variant)
            }
            fixture.press(Key.a)
            publish(fixture, generation: 3, change: Self.firstElement)
            let epoch = fixture.queue.caretEpoch  // every hard boundary breaks the caret continuity (PLT-R423)
            fixture.press(Key.a)
            let edits = fixture.popJobs().compactMap(\.edit)
            if continues {
                #expect(fixture.log.resets.isEmpty && fixture.log.continuedVariants == [.default])
                #expect(edits.map(\.insertion) == ["â"] && fixture.queue.caretEpoch == epoch)
            } else {
                #expect(fixture.log.madeVariants == [.default, code, .default])
                #expect(edits.isEmpty && fixture.queue.caretEpoch == epoch + 1)
            }
        }
    }

    /// Guard: another element after an unreadable snapshot is still a focus change. A word begun on the unreadable
    /// snapshot keeps the last-key window alone and is checked; a late one is a hard boundary.
    @Test func anotherElementAfterAnUnreadableSnapshotIsStillAFocusChangePLTR340() throws {
        let fixture = PipelineFixture()
        publish(fixture, generation: 2, after: 0, change: Self.timedOutRead)
        fixture.press(Key.a)
        publish(fixture, generation: 3)  // token 3: another field
        fixture.press(Key.a)
        #expect(fixture.log.resets.isEmpty)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.verifyLateFocus && edit.insertion == "â")

        let late = PipelineFixture()
        publish(late, generation: 2, after: 0, change: Self.timedOutRead)
        late.press(Key.a)
        publish(late, generation: 3, after: 600_000)
        late.press(Key.a)
        #expect(late.log.resets == [.focusChanged])
        #expect(lateFocusRecords(late).map(\.detail) == [LateFocusReason.lastKeyWindow.rawValue])
    }

    /// An element named after a snapshot of another process is no longer the known one, even with the same token.
    @Test func theKnownElementDoesNotSurviveAnotherProcessPLTR340() {
        let fixture = PipelineFixture()
        publish(fixture, generation: 2, pid: 300, after: 0) { $0.fieldHandle = nil }
        fixture.press(Key.a)
        publish(fixture, generation: 3, change: Self.firstElement)
        fixture.press(Key.a)
        #expect(fixture.log.resets == [.applicationChanged])
    }

    // MARK: Item 2: a same-process snapshot without a readable element

    /// VM run 20261118T214901Z (`sheet.commandS`, `đuơngf`): a same-process read timed out between `u` and `o`. The
    /// word goes on without a check (the worker cannot read the element); the sheet's field, published next, is
    /// judged against the element the word began in and checked.
    @Test func aSameProcessSnapshotWithoutAReadableElementKeepsTheWordPLTR340() throws {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.d, Key.d, Key.u])
        publish(fixture, generation: 2, after: 20_000, change: Self.timedOutRead)
        fixture.press(Key.o)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.completeJobs()) == 0)
        publish(fixture, generation: 3, after: 30_000)  // the sheet's field
        fixture.press(Key.w)
        #expect(fixture.log.resets.isEmpty)
        #expect(try #require(fixture.popJobs().compactMap(\.edit).last).verifyLateFocus)
        let reasons = lateFocusRecords(fixture).map(\.detail)
        #expect(reasons == [LateFocusReason.unreadable.rawValue, LateFocusReason.window.rawValue])
    }

    /// Every kind of snapshot without a readable element: no field handle, an element whose attributes timed out or
    /// failed, no focused element (AX answered), the PLT-R381 frontmost fallback.
    @Test(arguments: [0, 1, 2, 3, 4])
    func everySnapshotWithoutAReadableElementOfTheProcessKeepsTheWordPLTR340(kind: Int) {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.a])
        publish(fixture, generation: 2) { focus in
            switch kind {
            case 0: Self.timedOutRead(&focus)
            case 1: focus.field.axAvailability = .timedOut
            case 2: focus.field.axAvailability = .unavailable
            case 3: focus.fieldHandle = nil
            default:
                focus.fieldHandle = nil
                focus.app?.source = .frontmostApplication
                focus.field = FieldContext(
                    axAvailability: .available, role: nil, subrole: nil, identifier: nil, domClasses: [],
                    editable: nil, secure: false)
            }
        }
        fixture.press(Key.a)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 0)
    }

    /// The unreadable snapshot ends the word like any focus change when it names another process, pauses, changes
    /// the engine variant, or came more than 500 ms after the word's last key.
    @Test func anUnreadableSnapshotOutsideTheConditionsIsAHardBoundaryPLTR340() {
        let code = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        let cases: [(UInt64, Int32, LateFocusReason, (inout FocusSnapshot) -> Void)] = [
            (50_000, 300, .otherProcess, { _ in }),
            (50_000, 100, .paused, { $0.pause = .noTextFocus }),
            (50_000, 100, .variant, { $0.decision = PipelineFixtures.decision(variant: code) }),
            (600_000, 100, .lastKeyWindow, { _ in }),
        ]
        for (after, pid, reason, change) in cases {
            let fixture = PipelineFixture()
            typeWord(fixture, [Key.a])
            publish(fixture, generation: 2, pid: pid, after: after) { focus in
                focus.fieldHandle = nil
                change(&focus)
            }
            fixture.press(Key.a)
            #expect(fixture.popJobs().compactMap(\.edit).isEmpty)  // the second "a" does not continue the word
            #expect(lateFocusRecords(fixture).map(\.detail) == [reason.rawValue])
        }
    }

    /// The 19/11 `textView` case with an unreadable snapshot in between: a word typed in one field, the focus moved
    /// by Accessibility to another field of the same process (no key the tap saw), and the first read of the new
    /// field timed out. The word began 660 ms before that snapshot, so it went into the old field: a hard boundary at
    /// once, not a word kept until the new field shows up.
    @Test func aWordThatStartedBeforeTheWindowIsAHardBoundaryAfterAnUnreadableSnapshotPLTR340() {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.d, Key.u, Key.w, Key.s], every: 120_000)
        _ = fixture.popJobs()
        publish(fixture, generation: 2, after: 180_000, change: Self.timedOutRead)  // 300 ms after "s", 660 after "d"
        fixture.clock.advance(byMicroseconds: 100_000)
        #expect(fixture.keyDown(Key.a) == .pass)  // a new word
        #expect(fixture.log.resets == [.focusChanged])
        #expect(lateFocusRecords(fixture).map(\.detail) == [LateFocusReason.firstKeyWindow.rawValue])
    }

    /// An element named with an unreadable snapshot (its attribute read timed out) is not where the word began: once
    /// readable it is judged against the word's element and checked, not taken as the same owner.
    @Test func aReadableSnapshotOfTheUnreadableElementIsStillCheckedPLTR340() throws {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.a])
        publish(fixture, generation: 2) { $0.field.axAvailability = .timedOut }
        fixture.press(Key.s)
        #expect(checks(fixture.completeJobs()) == 0)
        publish(fixture, generation: 3) { $0.fieldHandle = FieldHandle(pid: 100, token: 2, element: nil) }
        fixture.press(Key.s)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 1)
    }

    // MARK: Item 3: a word typed right after a focus-moving trigger

    /// T5.5 on a loaded guest: Command+S, then `dduown` at 110 ms per key; the sheet's field is published 590 ms after
    /// the first key that followed Command+S. The trigger is the known cause of the change, so the first-key window
    /// does not apply: the word is kept and checked (the last-key window still decides).
    @Test func aWordTypedAfterATriggerIsMeasuredFromItsLastKeyPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.clock.advance(byMicroseconds: 600_000)
        fixture.press(Key.s, flags: Flag.command)
        for key in [Key.d, Key.d, Key.u, Key.o, Key.w, Key.n] {
            fixture.clock.advance(byMicroseconds: 110_000)
            fixture.press(key)
            fixture.completeJobs()
        }
        publish(fixture, generation: 2, after: 40_000)  // 590 ms after the first "d", 40 after "n"
        fixture.press(Key.g)
        #expect(fixture.log.resets.isEmpty)
        #expect(try #require(fixture.popJobs().compactMap(\.edit).first).verifyLateFocus)
        let records = lateFocusRecords(fixture)
        #expect(records.map(\.detail) == [LateFocusReason.trigger.rawValue])
        #expect(records.first?.a == 40_000 && records.first?.b == 590_000)
    }

    /// Items 2 and 3 together (`sheet.commandS` on a loaded guest): Command+S, `ddu`, a timed-out read of the sheet,
    /// `own`, and the field published 590 ms after the first "d".
    @Test func theSheetFieldAfterATimedOutReadAndATriggerKeepsTheWordPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.clock.advance(byMicroseconds: 600_000)
        fixture.press(Key.s, flags: Flag.command)
        fixture.clock.advance(byMicroseconds: 110_000)
        typeWord(fixture, [Key.d, Key.d, Key.u])
        publish(fixture, generation: 2, after: 0, change: Self.timedOutRead)
        typeWord(fixture, [Key.o, Key.w])
        publish(fixture, generation: 3, after: 0)
        fixture.press(Key.n)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 1)
    }

    /// The trigger must come after the previous element was published (the sheet's own field took the trigger's
    /// change) and shortly before the word: otherwise the first-key window applies as before.
    @Test func aTriggerThatDidNotPrecedeTheWordDoesNotWaiveTheFirstKeyWindowPLTR340() {
        let used = PipelineFixture()
        used.clock.advance(byMicroseconds: 600_000)
        used.press(Key.s, flags: Flag.command)
        publish(used, generation: 2, after: 100_000)  // the sheet's field, published after the trigger
        typeWord(used, [Key.d, Key.u, Key.w, Key.s], every: 120_000)
        publish(used, generation: 3, after: 180_000)  // an Accessibility move, 660 ms after "d"
        used.press(Key.a)
        #expect(used.log.resets == [.focusChanged])

        let early = PipelineFixture()
        early.clock.advance(byMicroseconds: 600_000)
        early.press(Key.s, flags: Flag.command)
        early.clock.advance(byMicroseconds: 900_000)  // the word begins 900 ms after the trigger
        typeWord(early, [Key.d, Key.u, Key.w, Key.s], every: 120_000)
        publish(early, generation: 2, after: 180_000)
        early.press(Key.a)
        #expect(early.log.resets == [.focusChanged])
        #expect(lateFocusRecords(early).map(\.detail) == [LateFocusReason.firstKeyWindow.rawValue])
    }

    // MARK: Item 4: reason codes

    /// The structural checks name what refused the change (another process, no element or AX after a timed-out read
    /// without an app, a pause, the variant), integers only (PLT-R901).
    @Test func aStructuralRefusalIsRecordedWithItsReasonPLTR340() {
        let code = EngineVariant(appContext: .code, englishRestore: false, macros: false)
        let cases: [(LateFocusReason, Int32, (inout FocusSnapshot) -> Void)] = [
            (.otherProcess, 300, { _ in }),
            (.paused, 100, { $0.pause = .noTextFocus }),
            (.variant, 100, { $0.decision = PipelineFixtures.decision(variant: code) }),
        ]
        for (reason, pid, change) in cases {
            let fixture = PipelineFixture()
            fixture.press(Key.a)
            publish(fixture, generation: 2, pid: pid, change: change)
            fixture.press(Key.a)
            #expect(lateFocusRecords(fixture).map(\.detail) == [reason.rawValue])
        }
        // After a timed-out read without an app, any process may keep the word, but only with a readable element.
        let unreadable: [(LateFocusReason, (inout FocusSnapshot) -> Void)] = [
            (.noElement, { $0.fieldHandle = nil }), (.axUnavailable, { $0.field.axAvailability = .timedOut }),
        ]
        for (reason, change) in unreadable {
            let fixture = PipelineFixture()
            var appLess = PipelineFixtures.focus(generation: 2, changedAt: fixture.clock.now())
            appLess.app = nil
            appLess.fieldHandle = nil
            appLess.field.axAvailability = .timedOut
            fixture.publish(focus: appLess)
            fixture.press(Key.a)
            publish(fixture, generation: 3, pid: 300, change: change)
            fixture.press(Key.a)
            #expect(lateFocusRecords(fixture).map(\.detail) == [reason.rawValue])
        }
    }

    /// No record without an active word: nothing was kept or ended.
    @Test func noRecordWithoutAnActiveWordPLTR340() {
        let fixture = PipelineFixture()
        fixture.typeKeys([Key.a, Key.space])
        publish(fixture, generation: 2, pid: 300)
        fixture.press(Key.a)
        #expect(lateFocusRecords(fixture).isEmpty)
    }
}
