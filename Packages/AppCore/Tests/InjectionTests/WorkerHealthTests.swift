// SPDX-License-Identifier: GPL-3.0-or-later
//
// Health events and loss accounting at the worker level: the PLT-R420 completion fallback, per-job history
// mismatches in `axReplace` (4.5), event-creation failures (PLT-R312, ADR 0308), generation-discard reporting
// (PLT-R316, PLT-R801) and posting breaking while a script posts (ADR 0311).

import AppModel
import Diagnostics
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private func completionPlan(_ mode: InlineCompletionMode) -> InjectionPlan {
    Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = mode })
}

@Suite struct WorkerCompletionFallbackTests {
    /// PLT-R420: on AX timeout `axSelectionThenPlaceholder` uses the placeholder and counts one health event per
    /// focus session; a new focus generation reports again.
    @Test func axTimeoutRecordsOneHealthEventPerSessionPLTR420() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.timeout)
        let plan = completionPlan(.axSelectionThenPlaceholder)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.run()
        #expect(rig.field.text == "á")
        #expect(rig.poster.posted.keyDowns.first?.unicode.string == InjectionTiming.placeholder)
        #expect(rig.healthKinds() == [.fallbackActivated])
        #expect(rig.metrics.fallbackActivations.value == 1)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, replaced: "á", insertion: "à", plan: plan) }
        rig.run()
        #expect(rig.field.text == "à")
        #expect(rig.healthKinds() == [.fallbackActivated])  // rate-limited per focus session
        rig.generation.store(FocusGeneration(rawValue: 2))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "ả", plan: plan, generation: 2) }
        rig.run()
        #expect(rig.field.text == "ả")
        #expect(rig.healthKinds() == [.fallbackActivated, .fallbackActivated])
    }

    /// PLT-R420: plain `axSelection` falls back to no prefix, and still counts the health event.
    @Test func axUnavailableWithoutPlaceholderRecordsTheEventPLTR420() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.unavailable)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection)) }
        rig.run()
        #expect(rig.field.text == "á")
        #expect(rig.poster.posted.backspaceCount == 1)
        #expect(rig.healthKinds() == [.fallbackActivated])
    }

    /// PLT-R423: through the worker, a caret at the end gets a Forward Delete before each Backspace (Spotlight on
    /// macOS 27.2, `tiee` gave "tieê" at the retest of 15/11/2026).
    @Test func forwardDeleteRunsThroughTheWorkerPLTR423() {
        let field = SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: ["tieng.example"]))
        let rig = WorkerRig(field: field)
        for character in "tie" {
            field.apply(InjectionFieldWiring.keyDown(character, receivedAt: Fixture.start), layout: rig.layout)
        }
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "ê", plan: completionPlan(.forwardDelete))
        }
        rig.run()
        #expect(field.text == "tiê")
        #expect(rig.poster.posted.keyDowns.map(\.keyCode).prefix(2) == [.forwardDelete, .delete])
        #expect(rig.healthKinds().isEmpty)
        #expect(rig.metrics.fallbackActivations.value == 0)
    }

    /// PLT-R423: an AX read that times out or fails gets no Forward Delete and counts the PLT-R420 health event once
    /// per focus session.
    @Test(arguments: [FakeFocusedFieldAccess.Behaviour.timeout, .unavailable])
    func anUnreadableCaretRecordsTheHealthEventPLTR423(_ ax: FakeFocusedFieldAccess.Behaviour) {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(ax)
        let plan = completionPlan(.forwardDelete)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, replaced: "á", insertion: "à", plan: plan) }
        rig.run()
        #expect(rig.field.text == "à")
        #expect(!rig.poster.posted.keyDowns.contains { $0.keyCode == .forwardDelete })
        #expect(rig.healthKinds() == [.fallbackActivated])
        #expect(rig.metrics.fallbackActivations.value == 2)
    }

    /// PLT-R423: a caret before the end is normal editing, not a failure: no Forward Delete and no health event.
    @Test func aCaretBeforeTheEndIsNotAHealthEventPLTR423() {
        let field = SimulatedTextField(text: "viet")
        field.click(at: 3)
        let rig = WorkerRig(field: field)
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "ê", plan: completionPlan(.forwardDelete))
        }
        rig.run()
        #expect(field.text == "viêt")
        #expect(!rig.poster.posted.keyDowns.contains { $0.keyCode == .forwardDelete })
        #expect(rig.healthKinds().isEmpty)
    }
}

@Suite struct WorkerHistoryMismatchTests {
    /// 4.5: a caret before the composition start means the engine history is out of sync, not that the field
    /// mishandles AX. The job falls back, but `axReplace` stays enabled for the field.
    @Test func historyMismatchFallsBackWithoutDegradingTheSession() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let plan = Fixture.plan(.axReplace, fallback: [.backspaceReplace])
        let first = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 2, insertion: "xy", plan: plan) }
        rig.run()
        #expect(rig.outcome(first) == .executedWithFallback)
        #expect(rig.health.recent(limit: 10).map(\.detail) == [.fallback(from: .axReplace, to: .backspaceReplace)])
        let callsAfterFirst = rig.fieldAccess.callCount
        let postedAfterFirst = rig.poster.posted.count
        let second = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "z", plan: plan) }
        rig.run()
        #expect(rig.outcome(second) == .executed)
        #expect(rig.fieldAccess.callCount > callsAfterFirst)
        #expect(rig.poster.posted.count == postedAfterFirst)  // axReplace posts no key events
        #expect(rig.field.text.hasSuffix("z"))
    }
}

@Suite struct WorkerEventCreationTests {
    /// PLT-R312: a held key whose replay cannot be created is counted and reported, never dropped silently.
    @Test func eventCreationFailureCountsTheLossAndReportsItPLTR312() {
        let rig = WorkerRig()
        rig.poster.setMode(.failingCreation)
        rig.pushReplay(InjectionFieldWiring.keyDown("a", receivedAt: rig.clock.now()))
        rig.pushReplay(InjectionFieldWiring.keyDown("b", receivedAt: rig.clock.now()))
        rig.run()
        #expect(rig.logger.entries.count == 2)
        #expect(rig.metrics.lostWhilePostingBroken.value == 2)
        #expect(rig.health.recent(limit: 10).map(\.kind) == [.postingBroken])
        #expect(rig.health.recent(limit: 10).map(\.detail) == [.count(2)])
        #expect(rig.queue.inFlight == 0)
    }
}

@Suite struct WorkerGenerationDiscardReportTests {
    /// PLT-R316, PLT-R801: a burst of stale edits yields one `generationDiscard` event with the count, so it
    /// cannot evict older entries from the fixed-size health log.
    @Test func aBurstOfStaleEditsRecordsOneEventWithTheCount() {
        let rig = WorkerRig(field: SimulatedTextField(text: ""))
        for _ in 0..<40 {
            rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "x", generation: 1) }
        }
        rig.generation.store(FocusGeneration(rawValue: 2))
        rig.run()
        #expect(rig.health.recent(limit: 256).map(\.kind) == [.generationDiscard])
        #expect(rig.health.recent(limit: 256).map(\.detail) == [.count(40)])
        #expect(rig.field.text == String(repeating: "s", count: 40))
    }
}

/// Lets a poster or AX callback reach the rig's feedback, which exists only after the rig is built.
private final class FeedbackBox: @unchecked Sendable {
    var feedback: WorkerFeedback?
}

/// Marks posting broken on the first caret read, i.e. after the worker's own check and before any post.
private struct BreakingFieldAccess: FocusedFieldAccess {
    let base: any FocusedFieldAccess
    let box: FeedbackBox

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        box.feedback?.markPostingBroken()
        return base.selectedRange(field, timeout: timeout)
    }

    func caret(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldCaret> {
        box.feedback?.markPostingBroken()
        return base.caret(field, timeout: timeout)
    }

    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        base.text(field, in: range, timeout: timeout)
    }

    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan)
        -> AXCallResult<Void>
    {
        base.setSelectedRange(field, to: range, timeout: timeout)
    }

    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        base.setSelectedText(field, to: text, timeout: timeout)
    }
}

@Suite struct WorkerPostingBreaksMidScriptTests {
    /// ADR 0311: posting breaks after the first backspace pair. The rest of the edit is a counted loss, not a
    /// fallback activation, and the trigger is not replayed.
    @Test func postingBrokenDuringAScriptCountsALossNotAFallbackADR0311() {
        let field = SimulatedTextField(text: "ab")
        let layout = InjectionTestLayouts.qwerty()
        let box = FeedbackBox()
        let count = AtomicCounter()
        let poster = FakeEventPoster { posted in
            if case .synthetic(let event, _) = posted { field.apply(event, layout: layout) }
            count.increment()
            if count.value >= 2 { box.feedback?.markPostingBroken() }
        }
        let rig = WorkerRig(field: field, poster: poster)
        box.feedback = rig.feedback
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 2, insertion: "xy",
                plan: Fixture.plan(fallback: [.selectReplace, .passThrough]))
        }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.poster.posted.count == 2)
        #expect(rig.metrics.fallbackActivations.value == 0)
        #expect(rig.metrics.lostWhilePostingBroken.value == 1)
        #expect(rig.healthKinds() == [.postingBroken])
        #expect(rig.feedback.compositionResetCount == 1)
        #expect(rig.drainExpectations().count == 1)  // the posted backspace pair is echoed
        #expect(rig.queue.inFlight == 0)
    }

    /// ADR 0311: posting breaks after the worker checked it but before the first event of the edit: nothing was
    /// posted, the trigger is counted as lost and the edit is abandoned without a fallback event.
    @Test func postingBrokenBeforeTheFirstEventAbandonsTheEditADR0311() {
        let box = FeedbackBox()
        let rig = WorkerRig(
            field: SimulatedTextField(text: "a"), fieldAccessWrapper: { BreakingFieldAccess(base: $0, box: box) })
        box.feedback = rig.feedback
        let plan = Fixture.plan(
            parameters: Fixture.parameters { $0.inlineCompletion = .axSelection }, fallback: [.selectReplace])
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "x", plan: plan) }
        rig.run()
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.poster.posted.isEmpty)
        #expect(rig.metrics.fallbackActivations.value == 0)
        #expect(rig.metrics.lostWhilePostingBroken.value == 1)
        #expect(rig.healthKinds() == [.postingBroken])
        #expect(rig.feedback.compositionResetCount == 1)
        #expect(rig.queue.inFlight == 0)
    }
}
