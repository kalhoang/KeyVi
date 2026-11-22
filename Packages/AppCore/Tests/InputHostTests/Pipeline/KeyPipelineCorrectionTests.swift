// SPDX-License-Identifier: GPL-3.0-or-later
//
// The typo correction on the tap (spec/01-engine.md ENG-R1115, ENG-R1117, ENG-R1118, 1.1.0): a corrected commit is
// one edit job before the boundary key, like a restore at a commit; the restore key right after undoes it with a
// restore job whose deletion is wider than the empty active display (the shape of the revision undo, PLT-R353) and
// carries `LearningSignal.neverCorrect` to main, where it is stored at once. The host counts corrections and undos,
// never words (ENG-R1121, PRD-R45). Scripted engine: a token typed as shown whose raw keys end with `nn` commits as
// the raw keys without the last `n`.

import AppModel
import Injection
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private func fixture() -> PipelineFixture {
    PipelineFixture(settings: PipelineFixtures.settings(restore: .key(KeyCode(rawValue: Key.escape))))
}

/// Types `keys` one press at a time, finishing every job before the next press.
private func type(_ keys: [UInt16], into fixture: PipelineFixture) {
    for key in keys {
        fixture.press(key)
        fixture.completeJobs()
    }
}

/// `dann` is shown as typed and corrected to `dan` when it is committed.
private let mistyped: [UInt16] = [Key.d, Key.a, Key.n, Key.n]
private let period: UInt16 = 0x2F

private func neverCorrectSignals(_ notices: [MainNotice]) -> [String] {
    notices.compactMap { notice in
        if case .learning(.neverCorrect(let raw), _) = notice { return raw }
        return nil
    }
}

@Suite struct KeyPipelineCorrectionTests {
    /// ENG-R1115: one edit over the token's display with the correction, then the boundary key replayed after it.
    @Test func aCorrectedCommitIsOneEditJobBeforeTheBoundaryKey_ENGR1115() throws {
        let fixture = fixture()
        type(mistyped, into: fixture)
        fixture.keyDown(Key.space)
        let jobs = fixture.popJobs()
        #expect(jobs.map(\.kind) == [.edit, .replay])
        let edit = try #require(jobs.first?.edit)
        #expect(edit.kind == .compose)
        #expect(edit.deleteCount == 4 && edit.insertion == "dan")
        #expect(edit.replacedText == "dann")
        #expect(jobs.last?.replayed?.keyCode.rawValue == Key.space)
        #expect(neverCorrectSignals(fixture.mainNotices()).isEmpty)
    }

    /// ENG-R1117, PLT-R353: the restore key right after the commit replaces the correction and the space with the raw
    /// keys and the space: a restore job wider than the (empty) active display, no trigger to replay, the key consumed
    /// as the hotkey; the signal goes to main with the app typed in; the next press passes through.
    @Test func theUndoRightAfterIsARestoreWiderThanTheActiveDisplayAndCarriesTheSignal_ENGR1117() throws {
        let fixture = fixture()
        type(mistyped + [Key.space], into: fixture)
        _ = fixture.mainNotices()
        let verdict = fixture.press(Key.escape)
        #expect(verdict == .swallow)
        let edit = try #require(fixture.completeJobs().first?.edit)
        #expect(edit.kind == .restore)
        #expect(edit.replacedText == nil && edit.trigger == nil)
        #expect(edit.deleteCount == "dan".count + 1 && edit.insertion == "dann ")
        #expect(fixture.pipeline.keyState.lastCommit == nil)
        let notices = fixture.mainNotices()
        #expect(neverCorrectSignals(notices) == ["dann"])
        #expect(
            notices.contains {
                if case .learning(.neverCorrect, let bundle) = $0 {
                    bundle == PipelineFixtures.focus().app?.bundle
                } else {
                    false
                }
            })
        #expect(fixture.press(Key.escape) == .pass, "ENG-R702: the second press passes through")
        #expect(fixture.popJobs().allSatisfy { $0.edit == nil })
    }

    /// Review Focus 1 of the plan: after `dann.` the undo deletes the correction and the closer and types the raw
    /// keys and the same closer, so `dan.` becomes `dann.` with the `.` untouched in the result.
    @Test func theUndoAfterACloserDeletesTheCloserToo() throws {
        let fixture = fixture()
        type(mistyped + [period], into: fixture)
        fixture.press(Key.escape)
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.kind == .restore)
        #expect(edit.deleteCount == "dan.".count && edit.insertion == "dann.")
        #expect(neverCorrectSignals(fixture.mainNotices()) == ["dann"])
    }

    /// ENG-R1121, PRD-R45: counts since launch, from the decision and the signal alone; no word is kept.
    @Test func countersCountCorrectionsAndUndosNeverWords() {
        let fixture = fixture()
        let counters = fixture.context.counters
        type(mistyped + [Key.space], into: fixture)
        #expect(counters.correctionCount == 1 && counters.correctionUndoCount == 0)
        type([Key.escape], into: fixture)
        #expect(counters.correctionCount == 1 && counters.correctionUndoCount == 1)
        type(mistyped + [Key.returnKey] + [Key.d, Key.o, Key.space], into: fixture)
        #expect(counters.correctionCount == 2 && counters.correctionUndoCount == 1)
        // A toggle that only restores the active word is no undo of a correction.
        type([Key.a, Key.s, Key.escape], into: fixture)
        #expect(counters.correctionUndoCount == 1)
    }

    /// ENG-R1117: after Return the history is cleared (a hard boundary), so the restore key cannot undo a correction
    /// made at Return and carries no signal.
    @Test func aCorrectionAtReturnCannotBeUndone() {
        let fixture = fixture()
        type(mistyped + [Key.returnKey], into: fixture)
        _ = fixture.mainNotices()
        fixture.press(Key.escape)
        #expect(!fixture.popJobs().contains { $0.edit?.kind == .restore })
        #expect(neverCorrectSignals(fixture.mainNotices()).isEmpty)
    }
}
