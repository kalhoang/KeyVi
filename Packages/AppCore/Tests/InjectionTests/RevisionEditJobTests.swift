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

@Suite struct RevisionEditJobTests {
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
        let unverified = never.pushEdit { revisionJob(sequence: $0, previous: nil, verify: false) }
        never.run()
        #expect(never.outcome(unverified) == .executed)
        #expect(never.field.text == "tricky as hell")
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
}
