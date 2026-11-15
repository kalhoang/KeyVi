// SPDX-License-Identifier: GPL-3.0-or-later
//
// The bounds of the inline-completion reads, through the worker with a field that answers late. Retest of 16/11/2026,
// items 34 and 40: right after Spotlight opened on macOS 27.2, its field answered the PLT-R423 read in 16 to 21 ms,
// past the 15 ms bound PLT-R420 gives `axSelection`, so the job added no Forward Delete and `vieejt` gave "vieệt";
// a few seconds later the same read took under 1 ms. `forwardDelete` now has its own 50 ms bound (VERIFY), while
// `axSelection` keeps 15 ms.

import AppModel
import Diagnostics
import InputHost
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private func completionPlan(_ mode: InlineCompletionMode) -> InjectionPlan {
    Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = mode })
}

/// A Spotlight-like field showing its suggestion after the caret once `typed` is in it.
private func suggestingAfterCaret(_ typed: String, layout: LayoutTable) -> SimulatedTextField {
    let field = SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: ["viet.example"]))
    for character in typed {
        field.apply(InjectionFieldWiring.keyDown(character, receivedAt: Fixture.start), layout: layout)
    }
    return field
}

/// A browser-like field whose suggestion is selected after the caret once `a` is typed.
private func selectingSuggestion(layout: LayoutTable) -> SimulatedTextField {
    let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
    field.apply(InjectionFieldWiring.keyDown("a", receivedAt: Fixture.start), layout: layout)
    return field
}

@Suite struct CompletionReadTimeoutTests {
    @Test func theForwardDeleteReadHasItsOwnLongerBoundPLTR423() {
        #expect(InjectionTiming.forwardDeleteReadTimeout == .milliseconds(50))
        #expect(InjectionTiming.axSelectionTimeout == .milliseconds(15))  // PLT-R420 unchanged
    }

    /// PLT-R423: a field that answers after 20 ms (Spotlight while it opens) still gets its Forward Delete before the
    /// Backspace, so the suggestion after the caret cannot take the deletion.
    @Test func aReadAnsweringAfter20msGetsForwardDeletePLTR423() {
        let layout = InjectionTestLayouts.qwerty()
        let field = suggestingAfterCaret("vie", layout: layout)
        #expect(!field.suggestionShown.isEmpty)
        let rig = WorkerRig(field: field)
        rig.fieldAccess.setReadLatency(.milliseconds(20), clock: rig.clock)
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "ê", plan: completionPlan(.forwardDelete))
        }
        rig.run()
        #expect(field.text == "viê")
        #expect(rig.poster.posted.keyDowns.map(\.keyCode).prefix(2) == [.forwardDelete, .delete])
        #expect(rig.healthKinds().isEmpty)
        #expect(rig.metrics.fallbackActivations.value == 0)
    }

    /// PLT-R423: a read slower than the bound gives up after 50 ms, not 15: no Forward Delete (the caret is unknown),
    /// and the PLT-R420 health event once per focus session while every fallback is counted.
    @Test func aReadSlowerThan50msGetsNoneAndCountsOncePerSessionPLTR423() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setReadLatency(.milliseconds(60), clock: rig.clock)
        let plan = completionPlan(.forwardDelete)
        let started = rig.clock.now()
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, replaced: "á", insertion: "à", plan: plan) }
        rig.run()
        #expect(rig.field.text == "à")
        #expect(!rig.poster.posted.keyDowns.contains { $0.keyCode == .forwardDelete })
        #expect(rig.healthKinds() == [.fallbackActivated])
        #expect(rig.metrics.fallbackActivations.value == 2)
        // Each read waited its whole bound: 2 x 50 ms (no pacing in the default plan).
        #expect(rig.clock.now().duration(since: started) == .milliseconds(100))
    }

    /// PLT-R420: `axSelection` keeps its 15 ms bound. A selected suggestion that answers after 20 ms is unreadable
    /// (no extra Backspace, the health event, 15 ms spent); one that answers after 10 ms gets its extra Backspace.
    @Test func axSelectionStillTimesOutAfter15msPLTR420() {
        let layout = InjectionTestLayouts.qwerty()
        let late = WorkerRig(field: selectingSuggestion(layout: layout))
        late.fieldAccess.setReadLatency(.milliseconds(20), clock: late.clock)
        let started = late.clock.now()
        late.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection)) }
        late.run()
        #expect(late.poster.posted.backspaceCount == 1)
        #expect(late.healthKinds() == [.fallbackActivated])
        #expect(late.clock.now().duration(since: started) == .milliseconds(15))

        let prompt = WorkerRig(field: selectingSuggestion(layout: layout))
        prompt.fieldAccess.setReadLatency(.milliseconds(10), clock: prompt.clock)
        prompt.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: completionPlan(.axSelection))
        }
        prompt.run()
        #expect(prompt.poster.posted.backspaceCount == 2)
        #expect(prompt.field.text == "á")
        #expect(prompt.healthKinds().isEmpty)
    }

    /// One slow read changes nothing for the next edits: the PLT-R384 circuit breaker counts only the ax thread's
    /// focus reads, and a completion fallback degrades no strategy (it only reports, PLT-R420). Spotlight answered
    /// late only while it was opening, so the next edit of the same focus session reads again and gets its Forward
    /// Delete.
    @Test func aSlowReadDoesNotStopTheNextReadsPLTR423() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let plan = completionPlan(.forwardDelete)
        rig.fieldAccess.setReadLatency(.milliseconds(80), clock: rig.clock)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.run()
        #expect(!rig.poster.posted.keyDowns.contains { $0.keyCode == .forwardDelete })
        rig.fieldAccess.setReadLatency(.microseconds(500), clock: rig.clock)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, replaced: "á", insertion: "à", plan: plan) }
        rig.run()
        #expect(rig.field.text == "à")
        #expect(rig.fieldAccess.callCount == 2)
        let keyCodes = rig.poster.posted.keyDowns.map(\.keyCode)
        #expect(keyCodes.filter { $0 == .forwardDelete }.count == 1)
        #expect(keyCodes.suffix(3).prefix(2) == [.forwardDelete, .delete])
    }
}
