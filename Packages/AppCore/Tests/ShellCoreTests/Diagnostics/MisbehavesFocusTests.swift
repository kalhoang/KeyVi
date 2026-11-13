// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1205 step 6 (decision Q43, docs/decisions/0005-pa-decisions-2026-11-13.md): the "This app misbehaves"
// panel takes keyboard focus while the user describes the symptom (step 2) and during the final offers (step 5),
// so Tab and Full Keyboard Access reach its controls (PRD-R67), and gives keyboard focus back to the problem
// field before each guided-test candidate (step 3). The AppKit side (canBecomeKey, makeKey, handing focus back)
// is checked by hand; these tests pin the phase-to-focus policy it follows.

import AppModel
import CompatRules
import Diagnostics
import Injection
import InputHost
import RealtimeSupport
import Testing

@testable import ShellCore

@Suite struct MisbehavesFocusTests {
    static let takesFocus: [MisbehavesFlow.Step?] = [
        nil, .describe, .finished, .interrupted(.cancelled), .interrupted(.fieldNotEmpty),
    ]
    static let guidedTest: [MisbehavesFlow.Step] = [.confirmField, .testing(0), .testing(4), .askHuman(2)]

    @Test(arguments: takesFocus)
    func describeAndFinalStepsTakeKeyboardFocus_PLTR1205(step: MisbehavesFlow.Step?) {
        let focus = MisbehavesPanelFocus(step: step)
        #expect(focus == .panel)
        #expect(focus.panelCanBecomeKey, "PRD-R67: Tab and Full Keyboard Access reach the panel's controls")
        #expect(!focus.panelBecomesKeyOnlyIfNeeded, "a click on any control keeps the panel key")
        #expect(focus.actionOnEntry == .takeFocus)
    }

    @Test(arguments: guidedTest)
    func guidedTestStepsLeaveKeyboardFocusInTheProblemField_PLTR1205(step: MisbehavesFlow.Step) {
        let focus = MisbehavesPanelFocus(step: step)
        #expect(focus == .problemField)
        #expect(!focus.panelCanBecomeKey, "a click on Confirm, Stop, Yes or No must not take the field's focus")
        #expect(focus.actionOnEntry == .returnFocusToProblemField)
    }

    @Test func focusMovedAwayIsNotTakenBack() {
        // The user switched to another app during the test: the panel does not steal the focus from it, but
        // still becomes key when the user types into one of its fields.
        let focus = MisbehavesPanelFocus(step: .interrupted(.focusChanged))
        #expect(focus == .leftAlone)
        #expect(focus.panelCanBecomeKey)
        #expect(focus.panelBecomesKeyOnlyIfNeeded)
        #expect(focus.actionOnEntry == nil)
    }

    @Test func everyCandidateStartsWithTheProblemFieldFocused() {
        #expect(MisbehavesPanelFocus.actionBeforeEachCandidate == .returnFocusToProblemField)
    }

    @Test func trackerMovesFocusOnlyWhenThePhaseChanges() {
        var tracker = MisbehavesFocusTracker()
        #expect(tracker.phase == nil)
        #expect(tracker.update(step: .describe) == .takeFocus, "the panel takes focus when it opens")
        #expect(tracker.update(step: .describe) == nil, "choosing a symptom does not move focus again")
        #expect(tracker.update(step: .confirmField) == .returnFocusToProblemField)
        #expect(tracker.update(step: .testing(0)) == nil)
        #expect(tracker.update(step: .askHuman(0)) == nil)
        #expect(tracker.update(step: .testing(1)) == nil)
        #expect(tracker.update(step: .finished) == .takeFocus)
        #expect(tracker.phase == .panel)
        #expect(tracker.update(step: .finished) == nil, "editing the page address does not move focus again")
    }

    @Test func stopTakesFocusButAFocusChangeDoesNot() {
        var stopped = MisbehavesFocusTracker()
        _ = stopped.update(step: .testing(0))
        #expect(stopped.update(step: .interrupted(.cancelled)) == .takeFocus)

        var moved = MisbehavesFocusTracker()
        _ = moved.update(step: .testing(0))
        #expect(moved.update(step: .interrupted(.focusChanged)) == nil)
        #expect(moved.phase == .leftAlone)
    }

    @Test func aGuidedTestRunTakesAndReturnsFocusInOrder() {
        // The real flow value drives the tracker: describe, gate, a readback failure, a human question, a pass.
        var flow = MisbehavesFlow(target: Self.target)
        var tracker = MisbehavesFocusTracker()
        var actions: [MisbehavesFocusAction?] = [tracker.update(step: flow.step)]
        flow.symptom = .duplicatedLetters
        actions.append(tracker.update(step: flow.step))
        flow.requestGuidedTest()
        actions.append(tracker.update(step: flow.step))
        flow.confirmFieldIsEmptyAndSafe()
        actions.append(tracker.update(step: flow.step))
        flow.record(.failedByReadback(residue: false))
        actions.append(tracker.update(step: flow.step))
        flow.record(.needsHumanAnswer)
        actions.append(tracker.update(step: flow.step))
        flow.answer(seesCanary: true)
        actions.append(tracker.update(step: flow.step))
        #expect(flow.step == .finished)
        #expect(actions == [.takeFocus, nil, .returnFocusToProblemField, nil, nil, nil, .takeFocus])
    }

    // PLT-R1205 steps 2 and 3: "Run a guided test..." is pressed in the key panel, so the live focus names this
    // app; the confirm step's target is read again once the focus is back in the problem field.
    @Test(arguments: [MisbehavesFlow.Step.describe, .confirmField])
    func theTargetFollowsTheLiveFocusBeforeTheTestStarts(step: MisbehavesFlow.Step) {
        #expect(MisbehavesRetarget.takesLiveFocus(step: step, liveFocusIsThisApp: false))
        #expect(!MisbehavesRetarget.takesLiveFocus(step: step, liveFocusIsThisApp: true), "never this app's panel")
    }

    static let keepsTarget: [MisbehavesFlow.Step?] = [
        nil, .testing(0), .askHuman(1), .finished, .interrupted(.cancelled), .interrupted(.focusChanged),
    ]

    @Test(arguments: keepsTarget)
    func theTargetIsKeptWithoutAFlowAndOnceTheTestHasStarted(step: MisbehavesFlow.Step?) {
        #expect(!MisbehavesRetarget.takesLiveFocus(step: step, liveFocusIsThisApp: false))
    }

    @Test func theTargetIsReadAgainSoonAfterTheFocusReturns() {
        let delays = MisbehavesRetarget.rereadDelays.map(\.nanoseconds)
        #expect(!delays.isEmpty)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(delays == delays.sorted(), "each read waits longer than the one before")
        #expect(delays.reduce(0, +) <= TimeSpan.seconds(1).nanoseconds, "the confirm step is corrected within a second")
    }

    static let target = MisbehavesTarget(
        app: FocusedApp(pid: 41, bundle: BundleKey(rawValue: "com.example.Editor")!, appVersion: nil, engine: .native),
        field: .unknown, fieldHandle: FieldHandle(pid: 41, token: 7, element: nil),
        focusGeneration: FocusGeneration(rawValue: 2), rule: nil, source: .default, plan: .default)
}
