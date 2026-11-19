// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R340 amendment (2026-11-14, Pa's T5.5 report): after a focus change the tap discovered late and kept the
// composition, the first job is applied only if the new element is readable and its text before the caret ends
// with the token's display (a selected inline completion after the caret allowed). Otherwise its key passes through
// and the composition is reset: the hard boundary it would have been. Bounded reads only (PLT-R343).

import AppModel
import Diagnostics
import Foundation
import InputHost
import RealtimeSupport
import Testing

@testable import Injection
@testable import TestSupport

private func lateFocusJob(
    _ sequence: UInt64, deleteCount: Int = 1, replaced: String? = "d", insertion: String = "đ",
    trigger: KeyEventRecord? = InjectionFieldWiring.keyDown("d", receivedAt: Fixture.start)
) -> EditJob {
    var job = Fixture.job(
        sequence: sequence, deleteCount: deleteCount, replaced: replaced, insertion: insertion, trigger: trigger)
    job.verifyLateFocus = true
    return job
}

/// An app still applying a key the tap passed through physically: the field reads without it until `due` on the
/// rig's clock (the first read of a selected range at or after `due` applies it). `onRead` runs before each
/// selected-range read with its index from 1; `timesOut` makes those reads time out.
private struct CatchingUpFieldAccess: FocusedFieldAccess {
    let base: FakeFocusedFieldAccess
    let field: SimulatedTextField
    /// The rig's clock, set once the rig exists (the wrapper is built inside the rig's initialiser).
    let clock: Mutex<ManualClock?>
    let due: MonotonicInstant
    let pending: Character
    var timesOut: Set<Int> = []
    var onRead: @Sendable (Int) -> Void = { _ in }
    private let state = Mutex((reads: 0, applied: false))

    init(
        base: FakeFocusedFieldAccess, field: SimulatedTextField, clock: Mutex<ManualClock?>, due: MonotonicInstant,
        pending: Character, timesOut: Set<Int> = [], onRead: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.base = base
        self.field = field
        self.clock = clock
        self.due = due
        self.pending = pending
        self.timesOut = timesOut
        self.onRead = onRead
    }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        let (index, apply) = state.withLock { state in
            state.reads += 1
            let apply = !state.applied && clock.withLock { $0?.now() ?? .zero } >= due
            if apply { state.applied = true }
            return (state.reads, apply)
        }
        onRead(index)
        if apply {
            self.field.apply(
                InjectionFieldWiring.keyDown(pending, receivedAt: due), layout: InjectionTestLayouts.qwerty())
        }
        if timesOut.contains(index) { return .timedOut }
        return base.selectedRange(field, timeout: timeout)
    }
    func caret(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldCaret> {
        base.caret(field, timeout: timeout)
    }
    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        base.text(field, in: range, timeout: timeout)
    }
    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        base.setSelectedRange(field, to: range, timeout: timeout)
    }
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        base.setSelectedText(field, to: text, timeout: timeout)
    }
}

/// A rig whose field (`text`) gets the token's "d" only `lag` milliseconds after the job's key (`Fixture.start`).
private func catchingUpRig(
    text: String = "", lagMilliseconds: UInt64, timesOut: Set<Int> = [],
    onRead: @escaping @Sendable (Int) -> Void = { _ in }
) -> WorkerRig {
    let field = SimulatedTextField(text: text)
    let due = Fixture.start.advanced(byMicroseconds: lagMilliseconds * 1_000)
    var access: CatchingUpFieldAccess?
    let rig = WorkerRig(field: field) { base in
        let wrapper = CatchingUpFieldAccess(
            base: base, field: field, clock: Mutex(nil), due: due, pending: "d", timesOut: timesOut, onRead: onRead)
        access = wrapper
        return wrapper
    }
    access?.clock.withLock { $0 = rig.clock }
    return rig
}

@Suite struct WorkerLateFocusTests {
    // MARK: A field still catching up (PLT-R340 amendment of 19/11/2026)

    /// VM run 20261118T220253Z: the check read the field about 5 ms after the tap passed the token's key through,
    /// before the app had inserted it (caret at 0). A failed first read within `InjectionTiming.revisionSettle` of
    /// the key is read once more when that window ends, as for a revision (PLT-R357), so the word is kept.
    @Test(arguments: [0, 1])
    func aFieldStillCatchingUpIsReadAgainAfterTheSettleWindowPLTR340(timedOutReads: Int) {
        let rig = catchingUpRig(lagMilliseconds: 20, timesOut: timedOutReads == 1 ? [1] : [])
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "đ")
        #expect(rig.feedback.compositionResetCount == 0)
        #expect(rig.clock.now() >= Fixture.start.advanced(byMicroseconds: 50_000))
    }

    /// Review of 19/11/2026: in a busy app the first read can cost both bounded calls (the second one timing out)
    /// and end after the 50 ms window. A read that started within the window and ended at most one call timeout
    /// after it is read once more at once (worst case 50 + 30 + 60 = 140 ms after the key, PLT-R314); one that ended
    /// later is not.
    @Test(arguments: [(60_000 as UInt64, true), (90_000 as UInt64, false)])
    func aSlowFirstReadStartedInTheWindowIsReadAgainPLTR340(cost: UInt64, readsAgain: Bool) {
        let clock = Mutex<ManualClock?>(nil)
        let rig = catchingUpRig(lagMilliseconds: 20, timesOut: [1]) { read in
            if read == 1 { clock.withLock { $0?.advance(byMicroseconds: cost) } }
        }
        clock.withLock { $0 = rig.clock }
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == (readsAgain ? .executed : .passedThroughByFallback))
        #expect(rig.feedback.compositionResetCount == (readsAgain ? 0 : 1))
        #expect(rig.clock.now() >= Fixture.start.advanced(byMicroseconds: cost))
    }

    /// Review of 19/11/2026: the window runs from the worker's last posted event when that came after the key, but
    /// PLT-R314 measures the held key from the key itself. With the previous edit posted 20 ms after the key, a first
    /// read that ends 100 ms after it still started in the window, yet a second read (two calls of 30 ms) could end
    /// 160 ms after the key and the liveness flush would reset the word after a matching check. The second read runs
    /// only when it can end within the ceiling (150 ms after the key); a faster first read keeps it.
    @Test(arguments: [(80_000 as UInt64, false), (40_000 as UInt64, true)])
    func theSecondReadEndsWithinTheLivenessCeilingOfTheKeyPLTR314(cost: UInt64, readsAgain: Bool) {
        let clock = Mutex<ManualClock?>(nil)
        let reads = Mutex(0)
        let rig = catchingUpRig(lagMilliseconds: 20, timesOut: [1]) { read in
            reads.withLock { $0 = read }
            if read == 1 { clock.withLock { $0?.advance(byMicroseconds: cost) } }
        }
        clock.withLock { $0 = rig.clock }
        rig.clock.advance(byMicroseconds: 20_000)  // the previous edit posts its last event 20 ms after the key
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: " ") }
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == (readsAgain ? .executed : .passedThroughByFallback))
        #expect(reads.withLock { $0 } == (readsAgain ? 2 : 1))
        #expect(rig.feedback.compositionResetCount == (readsAgain ? 0 : 1))
    }

    /// Bounded: one more read only. An app still behind when the window ends fails the check (the key passes and
    /// the word is reset), and a first read that already ends after the window is not repeated.
    @Test func theSecondReadIsTheLastPLTR340() {
        let slow = catchingUpRig(lagMilliseconds: 80)
        let edit = slow.pushEdit { lateFocusJob($0) }
        slow.run()
        #expect(slow.outcome(edit) == .passedThroughByFallback)
        #expect(slow.feedback.compositionResetCount == 1)

        let late = WorkerRig(field: SimulatedTextField(text: "Report"))
        late.clock.advance(byMicroseconds: 60_000)  // the job starts 60 ms after its key
        let started = late.clock.now()
        let other = late.pushEdit { lateFocusJob($0) }
        late.run()
        #expect(late.outcome(other) == .passedThroughByFallback)
        #expect(late.clock.now() == started)  // no wait
    }

    /// PLT-R316: a focus change while the worker waited (a click is never held, PLT-R317) discards the job: its key
    /// is replayed into the new field and the word is reset, nothing is posted.
    @Test func aFocusChangeDuringTheWaitDiscardsTheJobPLTR316() {
        let generation = Mutex<CurrentFocusGeneration?>(nil)
        let rig = catchingUpRig(lagMilliseconds: 20) { read in
            if read == 2 { generation.withLock { $0?.store(FocusGeneration(rawValue: 2)) } }
        }
        generation.withLock { $0 = rig.generation }
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .discardedForGeneration)
        #expect(rig.poster.posted.backspaceCount == 0)
        #expect(rig.feedback.compositionResetCount >= 1)
    }

    /// The sheet's name field shows the first "d" before the caret: the second "d" turns it into "đ".
    @Test func aMatchingFieldAppliesTheEditPLTR340() {
        let rig = WorkerRig(field: SimulatedTextField(text: "d"))
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "đ")
        #expect(rig.feedback.compositionResetCount == 0)
    }

    /// An inline completion selected after the caret does not hide the token: the text before the selection is
    /// compared, and the strategy removes the suggestion as usual.
    @Test func aSelectedCompletionAfterTheCaretIsAllowedPLTR340() {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["dao.example"]))
        field.apply(InjectionFieldWiring.keyDown("d", receivedAt: Fixture.start), layout: InjectionTestLayouts.qwerty())
        #expect(field.selection.length > 0)
        let rig = WorkerRig(field: field)
        var parameters = InjectionParameters.defaults
        parameters.inlineCompletion = .axSelection
        let edit = rig.pushEdit { sequence in
            var job = lateFocusJob(sequence)
            job.plan = Fixture.plan(parameters: parameters)
            return job
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text.hasPrefix("đ"))
    }

    @Test func aMismatchPassesTheKeyAndResetsPLTR340() {
        let rig = WorkerRig(field: SimulatedTextField(text: "Report"))
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "Reportd")  // the key as typed, nothing deleted
        #expect(rig.feedback.compositionResetCount == 1)
    }

    /// A failed check leaves one content-free focus record, a passed one none, so an integration run shows which
    /// kept words the field did not confirm (PLT-R340, PLT-R901).
    @Test func aFailedCheckIsLoggedWithoutContentPLTR340() {
        func checkFailures(_ rig: WorkerRig) -> Int {
            rig.logger.entries.filter { if case .focus(.lateFocusCheckFailed) = $0.event { true } else { false } }
                .count
        }
        let failed = WorkerRig(field: SimulatedTextField(text: "Report"))
        failed.pushEdit { lateFocusJob($0) }
        failed.run()
        #expect(checkFailures(failed) == 1)
        let passed = WorkerRig(field: SimulatedTextField(text: "d"))
        passed.pushEdit { lateFocusJob($0) }
        passed.run()
        #expect(checkFailures(passed) == 0)
    }

    /// Review of W8-A: the token begins after a separator or at the start of the text, so text that merely ends
    /// with it ("Nova" for the token "a", a focus move the app made by itself) is not the word being typed: the edit
    /// would delete a letter the user never typed ("Nová").
    @Test func textEndingWithTheTokenInsideAWordPassesTheKeyAndResetsPLTR340() {
        let rig = WorkerRig(field: SimulatedTextField(text: "Nova"))
        let edit = rig.pushEdit { lateFocusJob($0, replaced: "a", insertion: "á") }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "Novad")
        #expect(rig.feedback.compositionResetCount == 1)
    }

    /// A separator before the token (a composer that already holds earlier words) keeps the word.
    @Test(arguments: ["hello d", "hello,d", "(d", "line\nd"])
    func aSeparatorBeforeTheTokenKeepsTheWordPLTR340(_ text: String) {
        let rig = WorkerRig(field: SimulatedTextField(text: text))
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == String(text.dropLast()) + "đ")
    }

    /// Strict, unlike re-entry verification (`whenReadable`): an element that cannot be read is a hard boundary.
    @Test(arguments: [FakeFocusedFieldAccess.Behaviour.unavailable, .timeout])
    func anUnreadableFieldPassesTheKeyAndResetsPLTR340(_ behaviour: FakeFocusedFieldAccess.Behaviour) {
        let rig = WorkerRig(field: SimulatedTextField(text: "d"))
        rig.fieldAccess.setBehaviour(behaviour)
        let edit = rig.pushEdit { lateFocusJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "dd")
        #expect(rig.feedback.compositionResetCount == 1)
    }

    @Test func noFieldOrNoExpectedTextFailsPLTR340() {
        for change in [{ (job: inout EditJob) in job.field = nil }, { $0.replacedText = nil }] {
            let rig = WorkerRig(field: SimulatedTextField(text: "d"))
            let edit = rig.pushEdit { sequence in
                var job = lateFocusJob(sequence)
                change(&job)
                return job
            }
            rig.run()
            #expect(rig.outcome(edit) == .passedThroughByFallback)
            #expect(rig.feedback.compositionResetCount == 1)
        }
    }

    /// The check of a key without an edit (the pipeline holds the key behind it as a replay): a match posts nothing
    /// and keeps the composition, a mismatch posts nothing and resets it. The replay delivers the key either way.
    @Test func aCheckWithoutAnEditPostsNothingPLTR340() {
        let matching = WorkerRig(field: SimulatedTextField(text: "d"))
        let kept = matching.pushEdit { lateFocusJob($0, deleteCount: 0, insertion: "", trigger: nil) }
        matching.run()
        #expect(matching.outcome(kept) == .executed)
        #expect(matching.poster.posted.isEmpty && matching.feedback.compositionResetCount == 0)

        let other = WorkerRig(field: SimulatedTextField(text: "x"))
        let dropped = other.pushEdit { lateFocusJob($0, deleteCount: 0, insertion: "", trigger: nil) }
        other.run()
        #expect(other.outcome(dropped) == .passedThroughByFallback)
        #expect(other.poster.posted.isEmpty && other.feedback.compositionResetCount == 1)
    }

    /// Unflagged jobs never pay for the read (PLT-R343).
    @Test func anUnflaggedJobIsNotChecked() {
        let rig = WorkerRig(field: SimulatedTextField(text: "Report"))
        let edit = rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, replaced: "d", insertion: "đ")
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.fieldAccess.callCount == 0)
    }
}
