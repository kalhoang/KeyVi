// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R340, third review of the late focus identity rule (19/11/2026, integration-suite.md section 10.9): a trigger
// waives the first-key window only for a change observed within `LateFocusChange.triggerWindowNanoseconds` of it; a
// pending check goes with the next job whatever the snapshot, so no edit goes out unverified; a snapshot without a
// process after a timed-out or failed system-wide read is judged like a same-process one without a readable element;
// the decision kept for the last element is the last one resolved with its attributes. Integers only (PLT-R901).

import AppModel
import Diagnostics
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

@Suite struct LateFocusBoundsTests {
    /// A snapshot of the fixture's app (pid 100) observed `after` microseconds from now; the clock then moves past it.
    /// `PipelineFixtures.focus` names the element by its generation (token = generation) unless `change` says
    /// otherwise.
    private func publish(
        _ fixture: PipelineFixture, generation: UInt64, after microseconds: UInt64 = 50_000,
        change: (inout FocusSnapshot) -> Void = { _ in }
    ) {
        var focus = PipelineFixtures.focus(
            generation: generation, changedAt: fixture.clock.now().advanced(byMicroseconds: microseconds))
        change(&focus)
        fixture.publish(focus: focus)
        fixture.clock.advance(byMicroseconds: microseconds + 30_000)
    }

    /// The same process without a readable element: its element read timed out (no field handle).
    private static func timedOutRead(_ focus: inout FocusSnapshot) {
        focus.fieldHandle = nil
        focus.field.axAvailability = .timedOut
    }

    /// No process: the system-wide focus read timed out (`timedOut`) or failed (`unavailable`).
    private static func appLess(_ availability: AXAvailability) -> (inout FocusSnapshot) -> Void {
        { focus in
            focus.app = nil
            focus.fieldHandle = nil
            focus.field.axAvailability = availability
        }
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

    private func lateFocusReasons(_ fixture: PipelineFixture) -> [UInt16] {
        var reasons: [UInt16] = []
        fixture.tapLog.drain {
            if $0.code == .lateFocusKept || $0.code == .lateFocusRefused { reasons.append($0.detail) }
        }
        return reasons
    }

    private func checks(_ jobs: [InjectionJob]) -> Int { jobs.filter { $0.edit?.verifyLateFocus == true }.count }

    /// Command+S or a click, then 100 ms of nothing (the clock starts 600 ms in, so the trigger is not the first key).
    private func trigger(_ fixture: PipelineFixture, chord: Bool) {
        fixture.clock.advance(byMicroseconds: 600_000)
        if chord {
            fixture.press(Key.s, flags: Flag.command)
        } else {
            fixture.send(PipelineFixtures.keyEvent(.leftMouseDown, 0))
        }
        fixture.clock.advance(byMicroseconds: 100_000)
    }

    // MARK: Finding 1: the trigger explains a change only shortly after it

    /// Review of 19/11/2026: a word that began right after a shortcut or click, typed on for 1.3 s, and a field of the
    /// same process observed 300 ms after its last key, 1.62 s after its first and 1.72 s after the trigger. The
    /// trigger's reads (PLT-R389) ended long before, so it does not explain the change: the textView rule applies and
    /// the change is a hard boundary at once, not a kept word whose check fails one key late (`tieengs`).
    @Test(arguments: [true, false])
    func aChangeLongAfterTheTriggerIsMeasuredFromTheFirstKeyPLTR340(chord: Bool) {
        let fixture = PipelineFixture()
        trigger(fixture, chord: chord)
        let word = [Key.n, Key.g, Key.u, Key.e, Key.e, Key.n, Key.n, Key.g, Key.u, Key.e, Key.e, Key.n]
        typeWord(fixture, word, every: 120_000)
        _ = fixture.popJobs()
        publish(fixture, generation: 2, after: 180_000)
        fixture.press(Key.a)
        #expect(fixture.log.resets.last == .focusChanged)
        #expect(checks(fixture.popJobs()) == 0)
        #expect(lateFocusReasons(fixture) == [LateFocusReason.firstKeyWindow.rawValue])
    }

    /// The bound is `LateFocusChange.triggerWindowNanoseconds` (1 s) from the trigger to the change's `changedAt`:
    /// a sheet found 960 ms after Command+S is still the trigger's (kept, checked), one found 1,040 ms after it is not.
    @Test(arguments: [(140_000 as UInt64, true), (220_000 as UInt64, false)])
    func theTriggerWindowEndsOneSecondAfterTheTriggerPLTR340(after: UInt64, kept: Bool) {
        let fixture = PipelineFixture()
        trigger(fixture, chord: true)
        typeWord(fixture, [Key.d, Key.d, Key.u, Key.o, Key.w, Key.n], every: 120_000)  // "n" 700 ms after the trigger
        _ = fixture.popJobs()
        publish(fixture, generation: 2, after: after)  // 820 + after ms after the trigger
        fixture.press(Key.g)
        let reason = kept ? LateFocusReason.trigger : .firstKeyWindow
        #expect(lateFocusReasons(fixture) == [reason.rawValue])
        #expect(fixture.log.resets.isEmpty == kept)
        #expect(checks(fixture.popJobs()) == (kept ? 1 : 0))
    }

    // MARK: Finding 2: a pending check is never deferred

    /// Review of 19/11/2026: a kept change left its check pending (found at a keyUp), then a snapshot of the same
    /// process without a readable element kept the word. The next job still carries the check, with no field to
    /// read, so the worker fails closed (the key passes, the word is reset) instead of an edit going out blind into
    /// whatever has the focus (PLT-R316).
    @Test func aPendingCheckGoesWithTheNextJobWithoutAReadableElementPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.a)
        fixture.completeJobs()
        publish(fixture, generation: 2, after: 0)  // another field, readable: kept, check pending
        fixture.keyUp(Key.a)
        publish(fixture, generation: 3, after: 0, change: Self.timedOutRead)
        fixture.press(Key.s)
        let edit = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(edit.insertion == "á" && edit.verifyLateFocus && edit.field == nil)
        #expect(lateFocusReasons(fixture) == [LateFocusReason.window.rawValue, LateFocusReason.unreadable.rawValue])
    }

    /// The same for a key without an edit: the check job carries no field, and the key waits behind it.
    @Test func aPendingCheckGoesWithAKeyWithoutAnEditPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.a)
        fixture.completeJobs()
        publish(fixture, generation: 2, after: 0)
        fixture.keyUp(Key.a)
        publish(fixture, generation: 3, after: 0, change: Self.timedOutRead)
        fixture.press(Key.d)  // "ad": no edit
        let check = try #require(fixture.popJobs().compactMap(\.edit).first)
        #expect(check.verifyLateFocus && check.field == nil && check.insertion.isEmpty)
    }

    /// When the kept element is found again before the next key, that job checks it.
    @Test func aPendingCheckReadsTheKeptElementFoundAgainPLTR340() throws {
        let fixture = PipelineFixture()
        fixture.keyDown(Key.a)
        fixture.completeJobs()
        publish(fixture, generation: 2, after: 0)
        fixture.keyUp(Key.a)
        publish(fixture, generation: 3, after: 0, change: Self.timedOutRead)
        publish(fixture, generation: 4) { $0.fieldHandle = FieldHandle(pid: 100, token: 2, element: nil) }
        fixture.press(Key.s)
        let checked = fixture.popJobs().compactMap(\.edit).filter(\.verifyLateFocus)
        #expect(checked.count == 1 && checked.first?.field?.token == 2)
        #expect(fixture.log.resets.isEmpty)
    }

    // MARK: Finding 3: a snapshot without a process after a timed-out or failed read

    /// Review of 19/11/2026: both threads keep the last element across a snapshot without a process whose
    /// system-wide read timed out or failed, so mid-word it is judged like a same-process snapshot without a readable
    /// element: the word goes on without a check and the element found again is no focus change.
    @Test(arguments: [AXAvailability.timedOut, .unavailable])
    func anAppLessSnapshotAfterAFailedReadKeepsTheWordPLTR340(availability: AXAvailability) {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.d, Key.u])
        publish(fixture, generation: 2, after: 20_000, change: Self.appLess(availability))
        fixture.press(Key.w)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.completeJobs()) == 0)
        publish(fixture, generation: 3, after: 20_000, change: Self.firstElement)
        fixture.press(Key.s)
        #expect(fixture.log.resets.isEmpty)
        #expect(checks(fixture.popJobs()) == 0)
        let reasons = lateFocusReasons(fixture)
        #expect(reasons == [LateFocusReason.unreadable.rawValue, LateFocusReason.sameElement.rawValue])
    }

    /// After it, another field of the word's process is judged against the word's element and checked; another
    /// process ends the word.
    @Test func afterAnAppLessSnapshotTheNextOneIsJudgedAgainstTheWordsElementPLTR340() throws {
        let field = PipelineFixture()
        typeWord(field, [Key.d, Key.u])
        publish(field, generation: 2, after: 20_000, change: Self.appLess(.timedOut))
        field.press(Key.w)
        publish(field, generation: 3, after: 20_000)  // token 3: another field of pid 100
        field.press(Key.s)
        #expect(field.log.resets.isEmpty)
        #expect(try #require(field.popJobs().compactMap(\.edit).last).verifyLateFocus)

        let other = PipelineFixture()
        typeWord(other, [Key.d, Key.u])
        publish(other, generation: 2, after: 20_000, change: Self.appLess(.timedOut))
        other.press(Key.w)
        other.publish(focus: PipelineFixtures.focus(generation: 3, pid: 300, changedAt: other.clock.now()))
        other.press(Key.s)
        #expect(other.log.resets == [.applicationChanged])
        #expect(lateFocusReasons(other).last == LateFocusReason.otherProcess.rawValue)
    }

    /// Guards: AX answering that no application has the focus is a real change, and the first-key window still
    /// applies to an app-less snapshot after an element (it cannot say that the element did not change).
    @Test func anAppLessSnapshotOutsideTheConditionsIsAHardBoundaryPLTR340() {
        let answered = PipelineFixture()
        typeWord(answered, [Key.d, Key.u])
        publish(answered, generation: 2, after: 20_000, change: Self.appLess(.available))
        answered.press(Key.w)
        #expect(answered.log.resets == [.applicationChanged])
        #expect(lateFocusReasons(answered) == [LateFocusReason.otherProcess.rawValue])

        let late = PipelineFixture()
        typeWord(late, [Key.d, Key.u, Key.w, Key.s], every: 120_000)
        _ = late.popJobs()
        publish(late, generation: 2, after: 180_000, change: Self.appLess(.timedOut))  // 660 ms after "d"
        late.press(Key.a)
        #expect(late.log.resets == [.applicationChanged])
        #expect(lateFocusReasons(late) == [LateFocusReason.firstKeyWindow.rawValue])
    }

    // MARK: Finding 5: the decision kept for the last element

    /// Review of 19/11/2026: a read that found the element but timed out on its attributes resolves a bundle-level
    /// rule. Its own publication is a rule change (a boundary), but the decision kept for the element stays the one
    /// resolved with its attributes, so the element read in full again does not split the next word as well.
    @Test func anAttributeTimeoutDoesNotReplaceTheElementsDecisionPLTR340() {
        let fixture = PipelineFixture()
        typeWord(fixture, [Key.a])
        publish(fixture, generation: 2) { focus in
            Self.firstElement(&focus)
            focus.field.axAvailability = .timedOut
            focus.decision = PipelineFixtures.decision(strategy: .selectReplace)
        }
        fixture.press(Key.space)
        _ = fixture.completeJobs()
        let resetsBefore = fixture.log.resets.count
        typeWord(fixture, [Key.a])
        publish(fixture, generation: 3, change: Self.firstElement)  // read in full: the field's own decision
        fixture.press(Key.a)
        #expect(fixture.log.resets.count == resetsBefore)
        #expect(fixture.popJobs().compactMap(\.edit).map(\.insertion) == ["â"])
    }
}
