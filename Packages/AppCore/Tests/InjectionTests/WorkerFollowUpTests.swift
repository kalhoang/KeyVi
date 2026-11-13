// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Worker behaviour the pipeline relies on (W1-F1 requests): re-entry verification for every job the pipeline
// flags (PLT-R342), restore jobs without a trigger deliver nothing when they do not run (PLT-R312, ADR 0308), and
// ENG-R632: grapheme clusters drive Backspace events while UTF-16 units drive ranges, shown with an emoji macro.

import AppModel
import Diagnostics
import Foundation
import InputHost
import RealtimeSupport
import Testing

@testable import Injection
@testable import TestSupport

@Suite struct WorkerReentryKindTests {
    /// PLT-R342: the flag, not the kind, drives verification. The pipeline keeps `.macro` for a macro fired on a
    /// re-opened word and builds `.restore` jobs there too, and both still have to be checked against the field.
    @Test(arguments: [EditKind.reentry, .macro, .restore, .compose])
    func aFlaggedJobOnAMismatchingFieldWritesNothingPLTR342(_ kind: EditKind) {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chap"))
        let trigger: KeyEventRecord? = kind == .restore ? nil : Fixture.triggerS
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "chao", insertion: "ó", kind: kind, trigger: trigger,
                verifyBeforeApply: true)
        }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text.hasPrefix("xin chap"))  // the mismatching word is never deleted
        #expect(!rig.field.text.contains("ó"))
        #expect(rig.fieldAccess.callCount == 2)  // selection, then the word before the caret; no AX write
        #expect(rig.poster.posted.isEmpty == (trigger == nil))  // only the trigger is replayed, if there is one
    }

    @Test(arguments: [EditKind.reentry, .macro, .restore])
    func aFlaggedJobOnAMatchingFieldIsApplied(_ kind: EditKind) {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chao"))
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "chao", insertion: "ó", kind: kind, verifyBeforeApply: true)
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "xin chaó")
    }

    /// No flag, no AX read: edits of the word being typed never pay for a verification (PLT-R342, PLT-R343).
    @Test(arguments: [EditKind.compose, .backspaceRecompose, .reentry, .restore, .macro])
    func anUnflaggedJobIsNotVerified(_ kind: EditKind) {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chap"))
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "chao", insertion: "ó", kind: kind, verifyBeforeApply: false)
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "xin chaó")
        #expect(rig.fieldAccess.callCount == 0)
    }
}

/// A restore edit as the pipeline builds it: no trigger (its keyDown is consumed as a hotkey and its keyUp is
/// consumed whatever happens), so nothing must be posted when the edit does not run.
private func restoreJob(_ sequence: UInt64, plan: InjectionPlan = Fixture.plan(), generation: UInt64 = 1) -> EditJob {
    Fixture.job(
        sequence: sequence, deleteCount: 4, replaced: "chào", insertion: "chaof", plan: plan, generation: generation,
        kind: .restore, trigger: nil)
}

@Suite struct WorkerRestoreAbandonTests {
    @Test func aFlushedRestoreDeliversNothing() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chào"))
        let edit = rig.pushEdit { restoreJob($0) }
        rig.worker.requestFlush(.tapDisabled)
        rig.run()
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.poster.posted.isEmpty)
        #expect(rig.field.text == "xin chào")
    }

    @Test func aRestoreForAnOldGenerationDeliversNothingPLTR316() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chào"))
        rig.generation.store(FocusGeneration(rawValue: 2))
        let edit = rig.pushEdit { restoreJob($0, generation: 1) }
        rig.run()
        #expect(rig.outcome(edit) == .discardedForGeneration)
        #expect(rig.poster.posted.isEmpty)
        #expect(rig.field.text == "xin chào")
        #expect(rig.feedback.compositionResetCount == 1)
    }

    /// ADR 0311: with posting broken nothing is posted, and a restore has no key to count as lost.
    @Test func aRestoreWhilePostingIsBrokenCountsNoLossADR0311() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chào"))
        rig.feedback.markPostingBroken()
        let edit = rig.pushEdit { restoreJob($0) }
        rig.run()
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.poster.posted.isEmpty)
        #expect(rig.metrics.lostWhilePostingBroken.value == 0)
    }

    /// A restore whose chain ends in `passThrough` has no key to pass through.
    @Test func aRestoreFallingThroughToPassThroughDeliversNothing() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chào"))
        rig.fieldAccess.setBehaviour(.unavailable)
        let edit = rig.pushEdit { restoreJob($0, plan: Fixture.plan(.axReplace, fallback: [.passThrough])) }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.poster.posted.isEmpty)
        #expect(rig.field.text == "xin chào")
    }
}

/// "thân 👋🏽": 6 grapheme clusters, 9 UTF-16 units (the waving hand and its skin-tone modifier are one cluster
/// of four units).
private let expansion = "thân 👋🏽"

private func pasteReadyRig(text: String) -> WorkerRig {
    let pasteboard = FakePasteboard()
    return WorkerRig(
        field: SimulatedTextField(text: text, pasteboardText: { pasteboard.plainText }), pasteboard: pasteboard)
}

private func plan(_ strategy: InjectionStrategy, verify: Bool = false) -> InjectionPlan {
    Fixture.plan(
        strategy,
        parameters: Fixture.parameters {
            $0.pasteOptedIn = strategy == .paste
            $0.verifyAfterEdit = verify
        }, fallback: [.passThrough])
}

@Suite struct WorkerClusterCountTests {
    @Test func theExpansionHasMoreUTF16UnitsThanClusters() {
        #expect(expansion.count == 6)
        #expect(expansion.utf16.count == 9)
    }

    /// The macro expansion itself (ENG-R1103): two ASCII trigger letters out, the emoji text in.
    @Test(arguments: [InjectionStrategy.backspaceReplace, .selectReplace, .axReplace, .paste])
    func anEmojiMacroExpansionIsInsertedWhole(_ strategy: InjectionStrategy) {
        let rig = pasteReadyRig(text: "xin tn")
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 2, insertion: expansion, plan: plan(strategy), kind: .macro, trigger: nil)
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "xin " + expansion)
    }

    /// ENG-R632: undoing the expansion deletes 6 clusters: 6 Backspaces (or Shift+Left presses) for key-based
    /// strategies, a 9-unit range for AX selection. Using either count for the other would leave or eat text.
    @Test(arguments: [InjectionStrategy.backspaceReplace, .selectReplace, .axReplace, .paste])
    func removingTheExpansionCountsClustersForKeysAndUnitsForRangesENGR632(_ strategy: InjectionStrategy) {
        let rig = pasteReadyRig(text: "xin " + expansion)
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 6, deleteUTF16Count: 9, insertion: "tn", plan: plan(strategy),
                kind: .restore, trigger: nil)
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "xin tn")
        let keyDowns = rig.poster.posted.keyDowns
        switch strategy {
        case .backspaceReplace, .paste: #expect(rig.poster.posted.backspaceCount == 6)
        case .selectReplace: #expect(keyDowns.filter { $0.keyCode == .leftArrow }.count == 6)
        case .axReplace: #expect(keyDowns.isEmpty)
        case .passThrough: Issue.record("not a strategy under test")
        }
    }

    /// PLT-R402 trimming keeps both counts right: "t" is common, so 5 clusters / 8 units go.
    @Test(arguments: [InjectionStrategy.backspaceReplace, .axReplace])
    func prefixTrimmingRecountsUnitsFromTheRemovedClusters(_ strategy: InjectionStrategy) {
        let rig = pasteReadyRig(text: "xin " + expansion)
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 6, deleteUTF16Count: 9, replaced: expansion, insertion: "tn",
                plan: plan(strategy), kind: .restore, trigger: nil)
        }
        rig.run()
        #expect(rig.field.text == "xin tn")
        if strategy == .backspaceReplace { #expect(rig.poster.posted.backspaceCount == 5) }
    }

    /// PLT-R410: the readback after a key-based edit starts `deleteUTF16Count` units before the caret, so it
    /// reads exactly the insertion and records no mismatch.
    @Test(arguments: [InjectionStrategy.backspaceReplace, .paste])
    func readbackAfterRemovingTheExpansionUsesUTF16Units(_ strategy: InjectionStrategy) {
        let rig = pasteReadyRig(text: "xin " + expansion)
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 6, deleteUTF16Count: 9, insertion: "tn", plan: plan(strategy, verify: true),
                kind: .restore, trigger: nil)
        }
        rig.run()
        rig.clock.advance(byMicroseconds: 1_000_000)
        rig.run()
        #expect(rig.field.text == "xin tn")
        #expect(rig.healthKinds().isEmpty)
        #expect(rig.metrics.fallbackActivations.value == 0)
    }
}
