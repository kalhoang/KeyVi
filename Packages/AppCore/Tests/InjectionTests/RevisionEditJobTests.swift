// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R357: a commit that revises the previous token is one `.revision` job. Where the rule verifies (PLT-R342) the
// worker reads back the previous token, the space and the current display; on a mismatch it applies only the current
// token's part and resets the engine; any job that is not executed as computed resets the engine. The keycode is the
// first character's (PLT-R405), never the boundary key's. Worker in step mode over fakes.

import AppModel
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private let spaceTrigger = KeyCode(rawValue: 0x31)
private let periodTrigger = KeyCode(rawValue: 0x2F)
private let aKey = KeyCode(rawValue: 0x00)

/// `tricky á hell` typed, `hell` committed: the engine restores `á` to `as` (RV1). The engine's edit is minimal:
/// "á hell" -> "as hell" has no common prefix, so it deletes six graphemes.
private func revisionJob(
    sequence: UInt64, previous: CommittedToken? = CommittedToken(display: "á"), currentDisplay: String = "hell",
    deleteCount: Int = 6, insertion: String = "as hell", verify: Bool = true, trigger: KeyCode = spaceTrigger
) -> EditJob {
    var job = Fixture.job(
        sequence: sequence, deleteCount: deleteCount, insertion: insertion, kind: .revision, trigger: nil,
        verifyBeforeApply: verify,
        keyCodes: JobKeyCodes(trigger: trigger, firstCharacter: aKey, paste: KeyCode(rawValue: 0x09)))
    job.revision = RevisionEdit(previous: previous, currentDisplay: currentDisplay)
    return job
}

/// An app that applies posted events `lag` after they were posted, on the rig's clock; every field read first applies
/// what is due. Models the asynchronous delivery that makes a read-back right after posting see older text.
private final class LaggingApp: Sendable {
    private struct Pending: Sendable {
        var due: UInt64
        var posted: FakeEventPoster.Posted
    }

    let field: SimulatedTextField
    private let layout = InjectionTestLayouts.qwerty()
    private let lag: UInt64
    private let clock = Mutex<ManualClock?>(nil)
    private let pending = Mutex<[Pending]>([])

    init(field: SimulatedTextField, lagMilliseconds: UInt64) {
        self.field = field
        lag = lagMilliseconds * 1_000_000
    }

    func bind(_ clock: ManualClock) { self.clock.withLock { $0 = clock } }

    /// A key that passed through the tap physically (nothing in flight for the worker) and that the app applies
    /// `lag` after `at`.
    func holdPhysical(_ character: Character, at: MonotonicInstant) {
        let record = InjectionFieldWiring.keyDown(character, receivedAt: at)
        pending.withLock { $0.append(Pending(due: at.nanoseconds + lag, posted: .replay(record, userData: 0))) }
    }

    var poster: FakeEventPoster {
        FakeEventPoster { [self] posted in
            let now = clock.withLock { $0?.now().nanoseconds ?? 0 }
            pending.withLock { $0.append(Pending(due: now + lag, posted: posted)) }
        }
    }

    func catchUp() {
        let now = clock.withLock { $0?.now().nanoseconds ?? 0 }
        let due: [Pending] = pending.withLock { queue in
            let ready = Array(queue.prefix { $0.due <= now })
            queue.removeFirst(ready.count)
            return ready
        }
        for item in due {
            switch item.posted {
            case .synthetic(let event, _): field.apply(event, layout: layout)
            case .replay(let record, _): field.apply(record, layout: layout)
            }
        }
    }
}

/// Field access through a lagging app. `onRead` runs before each selected-range read with its index from 1: the
/// moment a click or a focus change lands between the worker's reads.
private struct LaggingFieldAccess: FocusedFieldAccess {
    let base: any FocusedFieldAccess
    let app: LaggingApp
    var onRead: @Sendable (Int) -> Void = { _ in }
    private let reads = Mutex(0)

    init(base: any FocusedFieldAccess, app: LaggingApp, onRead: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.base = base
        self.app = app
        self.onRead = onRead
    }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        let index = reads.withLock { count in
            count += 1
            return count
        }
        onRead(index)
        app.catchUp()
        return base.selectedRange(field, timeout: timeout)
    }
    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        app.catchUp()
        return base.text(field, in: range, timeout: timeout)
    }
    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        app.catchUp()
        return base.setSelectedRange(field, to: range, timeout: timeout)
    }
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        app.catchUp()
        return base.setSelectedText(field, to: text, timeout: timeout)
    }
}

/// A rig over a lagging app: `hel` is on screen, the job that types the last `l` comes first, then the revision.
private func laggingRevision(lagMilliseconds: UInt64) -> (WorkerRig, LaggingApp, UInt64) {
    let app = LaggingApp(field: SimulatedTextField(text: "tricky á hel"), lagMilliseconds: lagMilliseconds)
    let rig = WorkerRig(field: app.field, poster: app.poster) { LaggingFieldAccess(base: $0, app: app) }
    app.bind(rig.clock)
    rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "l") }
    let edit = rig.pushEdit { revisionJob(sequence: $0) }
    rig.run()
    rig.clock.advance(byMicroseconds: 500_000)
    app.catchUp()
    return (rig, app, edit)
}

/// A rig over a lagging app where the last letter of the current word passed through the tap physically: `hel` is
/// on screen and the app applies `l` `lag` after the trigger key; `postedBefore` adds a worker-posted job one second
/// earlier, so the worker's last posted event is old.
private func physicalLagRevision(lagMilliseconds: UInt64, postedBefore: Bool) -> (WorkerRig, LaggingApp, UInt64) {
    let app = LaggingApp(
        field: SimulatedTextField(text: postedBefore ? "tricky á he" : "tricky á hel"), lagMilliseconds: lagMilliseconds
    )
    let rig = WorkerRig(field: app.field, poster: app.poster) { LaggingFieldAccess(base: $0, app: app) }
    app.bind(rig.clock)
    if postedBefore {
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "l") }
        rig.run()
        rig.clock.advance(byMicroseconds: 1_000_000)
        app.catchUp()
    }
    let trigger = rig.clock.now()
    app.holdPhysical("l", at: trigger)
    let edit = rig.pushEdit { sequence in
        var job = revisionJob(sequence: sequence)
        job.createdAt = trigger
        return job
    }
    rig.run()
    rig.clock.advance(byMicroseconds: 500_000)
    app.catchUp()
    return (rig, app, edit)
}

@Suite struct RevisionEditJobTests {
    /// PLT-R357: the app has not applied the job before the revision when the read-back runs. The mismatch is read
    /// again once the settle window after the last posted event (later than the trigger here) ends, and the whole revision applies.
    @Test func aSlowAppIsReadAgainAfterTheSettleWindow() {
        let (rig, app, edit) = laggingRevision(lagMilliseconds: 20)
        #expect(rig.outcome(edit) == .executed)
        #expect(app.field.text == "tricky as hell")
        #expect(rig.feedback.compositionResetCount == 0)
    }

    /// The second read is the only one: an app slower than the settle window gets the current token's part.
    @Test func anAppSlowerThanTheSettleWindowGetsTheCurrentTokenOnly() {
        let (rig, app, edit) = laggingRevision(lagMilliseconds: 80)
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(app.field.text == "tricky á hell")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// The field shows what the engine expects: the whole revision applies, the engine keeps its history.
    @Test func aMatchingFieldGetsTheWholeRevisionPLTR357() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        let edit = rig.pushEdit { revisionJob(sequence: $0) }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "tricky as hell")
        #expect(rig.feedback.compositionResetCount == 0)
    }

    /// PLT-R405: the insertion rides on the first character's keycode, never on Space or `.`.
    @Test(arguments: [spaceTrigger, periodTrigger])
    func theInsertionNeverRidesOnTheBoundaryKey(_ trigger: KeyCode) {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        _ = rig.pushEdit { revisionJob(sequence: $0, trigger: trigger) }
        rig.run()
        let inserted = rig.poster.posted.keyDowns.filter { $0.keyCode != .delete }
        #expect(!inserted.isEmpty && inserted.allSatisfy { $0.keyCode == aKey })
        #expect(rig.poster.posted.backspaceCount == 6)
    }

    /// PLT-R342: the previous word on screen is not what the engine committed (autocorrect changed it): only the
    /// current token's part is applied and the engine is reset.
    @Test func aMismatchAppliesOnlyTheCurrentTokenAndResets() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky a hell"))
        let edit = rig.pushEdit { revisionJob(sequence: $0) }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "tricky a hell")
        #expect(rig.poster.posted.keyDowns.isEmpty, "the current token's part was already on screen")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// The current token's part is applied when it changes too (a revision that also restores the current token).
    @Test func theCurrentPartIsAppliedOnAMismatch() {
        let rig = WorkerRig(field: SimulatedTextField(text: "x tét"))
        let edit = rig.pushEdit {
            revisionJob(
                sequence: $0, previous: CommittedToken(display: "á"), currentDisplay: "tét", deleteCount: 5,
                insertion: "as test")
        }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "x test")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// The previous token's text is rebuilt from its own commit: kept prefix plus insertion, after the last space.
    @Test func thePreviousTokenIsRebuiltFromItsCommit() {
        #expect(CommittedToken(display: "tét", deleteCount: 2, insert: "est").text == "test")
        #expect(CommittedToken(display: "hell", deleteCount: 6, insert: "as hell").text == "hell")
        #expect(CommittedToken(display: "nha", deleteCount: 3, insert: "á nha").text == "nha")
        #expect(CommittedToken(display: "này").text == "này")
        let rig = WorkerRig(field: SimulatedTextField(text: "the test hell"))
        let edit = rig.pushEdit {
            revisionJob(
                sequence: $0, previous: CommittedToken(display: "tét", deleteCount: 2, insert: "est"),
                currentDisplay: "hell", deleteCount: 9, insertion: "tét hell")
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "the tét hell")
    }

    /// Unreadable fields apply the revision (`verifyReentry: whenReadable`); a rule that never verifies applies it
    /// without reading.
    @Test func unreadableOrUnverifiedFieldsApplyTheRevision() {
        let unreadable = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        unreadable.fieldAccess.setBehaviour(.unavailable)
        let applied = unreadable.pushEdit { revisionJob(sequence: $0) }
        unreadable.run()
        #expect(unreadable.outcome(applied) == .executed)
        #expect(unreadable.field.text == "tricky as hell")

        let never = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        let unverified = never.pushEdit { revisionJob(sequence: $0, verify: false) }
        never.run()
        #expect(never.outcome(unverified) == .executed)
        #expect(never.field.text == "tricky as hell")
    }

    /// PLT-R357: without the previous token the pipeline cannot say what the revision replaces, so the previous
    /// token is never rewritten, also where the rule never verifies: only the current token's part, then a reset.
    @Test func anUnknownPreviousTokenIsNeverRewrittenEvenWithoutVerification() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        let edit = rig.pushEdit { revisionJob(sequence: $0, previous: nil, verify: false) }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "tricky á hell")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// PLT-R340 amendment with PLT-R357: the first job after a focus change found late checks the current token's
    /// display (a revision job carries no replaced text), then the revision reads back the previous token as well,
    /// even where the rule never verifies, since the element is not the one the previous token was typed in for sure.
    @Test func aLateFocusChangeChecksTheCurrentTokenThenThePreviousOne() {
        let matching = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        let applied = matching.pushEdit { sequence in
            var job = revisionJob(sequence: sequence, verify: false)
            job.verifyLateFocus = true
            return job
        }
        matching.run()
        #expect(matching.outcome(applied) == .executed)
        #expect(matching.field.text == "tricky as hell")
        #expect(matching.feedback.compositionResetCount == 0)

        let otherPrevious = WorkerRig(field: SimulatedTextField(text: "x tét"))
        let partial = otherPrevious.pushEdit { sequence in
            var job = revisionJob(
                sequence: sequence, previous: CommittedToken(display: "á"), currentDisplay: "tét", deleteCount: 5,
                insertion: "as test", verify: false)
            job.verifyLateFocus = true
            return job
        }
        otherPrevious.run()
        #expect(otherPrevious.outcome(partial) == .executedWithFallback)
        #expect(otherPrevious.field.text == "x test")
        #expect(otherPrevious.feedback.compositionResetCount >= 1)

        let otherToken = WorkerRig(field: SimulatedTextField(text: "tricky á shell"))
        let passed = otherToken.pushEdit { sequence in
            var job = revisionJob(sequence: sequence)
            job.verifyLateFocus = true
            return job
        }
        otherToken.run()
        #expect(otherToken.outcome(passed) != .executed && otherToken.outcome(passed) != .executedWithFallback)
        #expect(otherToken.field.text.hasPrefix("tricky á shell"))
    }

    /// PLT-R357: a revision delivered by a fallback strategy (the primary failed before posting anything) is not the
    /// job as computed, so the engine is reset even though the text is right.
    @Test func aRevisionDeliveredByAFallbackResetsTheEngine() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        rig.fieldAccess.setBehaviour(.unavailable)
        let edit = rig.pushEdit { sequence in
            var job = revisionJob(sequence: sequence)
            job.plan = Fixture.plan(.axReplace, fallback: [.backspaceReplace])
            return job
        }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "tricky as hell")
        #expect(rig.feedback.compositionResetCount == 1)
    }

    /// Without the previous token the revision cannot be verified: only the current token, then a reset.
    @Test func anUnknownPreviousTokenIsNotRewrittenWhereTheRuleVerifies() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        let edit = rig.pushEdit { revisionJob(sequence: $0, previous: nil) }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "tricky á hell")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// PLT-R357: any job that is not executed as computed resets the engine (here a stale focus generation).
    @Test func aDiscardedRevisionResetsTheEngine() {
        let rig = WorkerRig(field: SimulatedTextField(text: "tricky á hell"))
        rig.generation.store(FocusGeneration(rawValue: 2))
        let edit = rig.pushEdit { revisionJob(sequence: $0) }
        rig.run()
        #expect(rig.outcome(edit) == .discardedForGeneration)
        #expect(rig.field.text == "tricky á hell")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// PLT-R357: the letters of the current word usually pass through the tap physically, so the worker has posted
    /// nothing recently. The settle window starts at the trigger key as well: an app 20 ms behind on the last
    /// physical letter still gets the whole revision, with or without an old posted event.
    @Test(arguments: [false, true])
    func aSlowAppBehindOnAPhysicalLetterIsReadAgain(postedBefore: Bool) {
        let (rig, app, edit) = physicalLagRevision(lagMilliseconds: 20, postedBefore: postedBefore)
        #expect(rig.outcome(edit) == .executed)
        #expect(app.field.text == "tricky as hell")
        #expect(rig.feedback.compositionResetCount == 0)
    }

    /// PLT-R316 with PLT-R357: the focus changed while the worker waited for the app to settle (a mouse click is
    /// never held, PLT-R317). Nothing is posted into the new field; the key is replayed and the engine reset.
    @Test func aFocusChangeDuringTheSettleWaitDiscardsTheRevision() {
        let app = LaggingApp(field: SimulatedTextField(text: "tricky á hel"), lagMilliseconds: 20)
        let focus = Mutex<CurrentFocusGeneration?>(nil)
        let rig = WorkerRig(field: app.field, poster: app.poster) { base in
            LaggingFieldAccess(base: base, app: app) { read in
                // The first read is the read-back, the second the one after the settle wait.
                if read == 2 { focus.withLock { $0?.store(FocusGeneration(rawValue: 2)) } }
            }
        }
        app.bind(rig.clock)
        focus.withLock { $0 = rig.generation }
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "l") }
        let edit = rig.pushEdit { revisionJob(sequence: $0) }
        rig.run()
        #expect(rig.outcome(edit) == .discardedForGeneration)
        #expect(rig.poster.posted.backspaceCount == 0)
        #expect(rig.poster.posted.insertedText == "l")
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// PLT-R357 with PLT-R342: the read-back found the field unlike the engine's text because the caret moved (a
    /// click between the trigger and the read). The current token is not before the caret either, so nothing is
    /// edited: the key passes through and the engine is reset.
    @Test func aMismatchWithTheCurrentTokenAwayFromTheCaretPassesTheKey() {
        let rig = WorkerRig(field: SimulatedTextField(text: "x tét"))
        rig.field.click(at: 1)
        let edit = rig.pushEdit {
            revisionJob(
                sequence: $0, previous: CommittedToken(display: "á"), currentDisplay: "tét", deleteCount: 5,
                insertion: "as test")
        }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "x tét")
        #expect(rig.poster.posted.keyDowns.isEmpty)
        #expect(rig.feedback.compositionResetCount >= 1)
    }
}
