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

@Suite struct WorkerLateFocusTests {
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
