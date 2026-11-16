// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R423 caret continuity (amendment of 16/11/2026, second retest of beta 2): in one Spotlight session on macOS 27.2
// the `forwardDelete` read took 3.2, 14.6 and 27.2 ms and then more than its 50 ms bound, because every edit changes
// the query and Spotlight's main thread is still searching when the next read arrives. The read that did not answer
// added no Forward Delete, so the suggestion after the caret took the first Backspace again. Once a read in the focus
// session found the caret at the end of the text, and since then nothing that can move the caret happened (the tap
// breaks the continuity on every such event, `JobQueue.breakCaretContinuity`), a read that does not answer keeps that
// answer. A fresh answer always wins.

import AppModel
import Diagnostics
import InputHost
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private let forwardDeletePlan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = .forwardDelete })

/// Spotlight as the trace showed it: a suggestion after the caret for every query below, offered again after each
/// deletion at the end of the text.
private let spotlightSuggestions = [
    "tieng", "tiêu", "tiếp", "viet", "viêm", "việt nam",
]

/// A worker in one focus session on a Spotlight-like field. Keys the tap passes reach the field directly, as they
/// reach the app; edits go through the worker.
private final class SpotlightSession {
    let rig: WorkerRig
    var field: SimulatedTextField { rig.field }

    init(
        field: SimulatedTextField = SimulatedTextField(
            behaviour: .suggestionAfterCaret(suggestions: spotlightSuggestions))
    ) {
        rig = WorkerRig(field: field)
    }

    func type(_ text: String) {
        for character in text {
            field.apply(InjectionFieldWiring.keyDown(character, receivedAt: Fixture.start), layout: rig.layout)
        }
    }

    /// Command+A as the app applies it; the tap breaks the continuity on the chord (tested in the pipeline suites).
    func selectAll() {
        rig.queue.breakCaretContinuity()
        field.axSetSelectedRange(Injection.TextRange(location: 0, length: field.text.utf16.count))
    }

    /// One edit whose completion read answers after `latency`. The job carries the epoch the tap stamps when it builds
    /// the job (`caretEpoch`, by default the current one). Returns the key codes this job posted.
    @discardableResult
    func edit(
        delete: Int, insert: String, latency: TimeSpan, generation: UInt64 = 1, caretEpoch: UInt64? = nil,
        plan: InjectionPlan = forwardDeletePlan, beforeRun: () -> Void = {}
    ) -> [KeyCode] {
        let before = rig.poster.posted.keyDowns.count
        rig.fieldAccess.setReadLatency(latency, clock: rig.clock)
        let epoch = caretEpoch ?? rig.queue.caretEpoch
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: delete, insertion: insert, plan: plan, generation: generation,
                caretEpoch: epoch)
        }
        beforeRun()
        rig.run()
        return rig.poster.posted.keyDowns.dropFirst(before).map(\.keyCode)
    }

    var forwardDeleteCount: Int { rig.poster.posted.keyDowns.filter { $0.keyCode == .forwardDelete }.count }
}

extension [KeyCode] {
    fileprivate var backspaces: Int { filter { $0 == .delete }.count }
}

@Suite struct CaretContinuityTests {
    /// The trace of 16/11/2026: `tieesng`, Command+A, `vieejt` typed over the selection. Reads of 3.2, 14.6 and
    /// 27.2 ms answer; the fourth takes longer than the 50 ms bound. Nothing moved the caret since the third read (the
    /// select-all chord came before it), so the fourth edit keeps its Forward Delete before each Backspace and the
    /// word comes out right. No health event: nothing degraded.
    @Test func readsThatGetSlowerKeepTheForwardDeleteWhileNothingMovedTheCaretPLTR423() {
        let session = SpotlightSession()
        session.type("tie")
        #expect(
            session.edit(delete: 1, insert: "ê", latency: .microseconds(3_200)).prefix(2) == [.forwardDelete, .delete])
        #expect(
            session.edit(delete: 1, insert: "ế", latency: .microseconds(14_600)).prefix(2) == [.forwardDelete, .delete])
        session.type("ng")
        #expect(session.field.text == "tiếng")
        session.selectAll()
        session.type("vie")
        #expect(
            session.edit(delete: 1, insert: "ê", latency: .microseconds(27_200)).prefix(2) == [.forwardDelete, .delete])
        #expect(!session.field.suggestionShown.isEmpty)
        let kept = session.edit(delete: 2, insert: "iệ", latency: .milliseconds(60))
        #expect(kept.prefix(4) == [.forwardDelete, .delete, .forwardDelete, .delete])
        session.type("t")
        #expect(session.field.text == "việt")
        #expect(session.forwardDeleteCount == 5)
        #expect(session.rig.healthKinds().isEmpty)
        #expect(session.rig.metrics.fallbackActivations.value == 0)
    }

    /// The same with every read slower than the first: 3, 15, 27 and 60 ms within one word stretch. Every edit gets
    /// its Forward Delete, and an answer kept once can be kept again by the next edit that times out.
    @Test func everyEditOfAClimbingSessionGetsItsForwardDeletePLTR423() {
        let session = SpotlightSession(
            field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: ["a.example"])))
        session.type("a")
        let latencies: [TimeSpan] = [
            .milliseconds(3), .milliseconds(15), .milliseconds(27), .milliseconds(60), .milliseconds(80),
        ]
        for latency in latencies {
            let posted = session.edit(delete: 1, insert: "a", latency: latency)
            #expect(posted.prefix(2) == [.forwardDelete, .delete], "read of \(latency)")
        }
        #expect(session.field.text == "a")
        #expect(session.rig.healthKinds().isEmpty)
    }

    /// A click, a navigation key, a selection chord (Shift with an arrow, Command+A), a paste or any other Command or
    /// Control chord reaches the worker as a broken continuity: after it a read that does not answer adds no Forward
    /// Delete (PLT-R407), and the health event of PLT-R420 is counted. Here the click put the caret after "tiếng" and
    /// the user typed `aa` there: a Forward Delete would have deleted the space after the caret.
    @Test func aCaretMoveBetweenEditsMakesATimedOutReadAddNothingPLTR407() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("tiếng vie")
        #expect(session.edit(delete: 1, insert: "ê", latency: .milliseconds(3)).first == .forwardDelete)
        session.rig.queue.breakCaretContinuity()  // the click, as the tap sees it
        session.field.click(at: 5)  // as the app applies it
        session.type("a")
        let posted = session.edit(delete: 1, insert: "â", latency: .milliseconds(60))
        #expect(!posted.contains(.forwardDelete))
        #expect(session.field.text == "tiếngâ viê")
        #expect(session.rig.healthKinds() == [.fallbackActivated])
    }

    /// A focus change (a new generation) ends the focus session: the answer read in the previous one is never kept.
    @Test func aFocusChangeEndsTheContinuityPLTR423() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("a")
        #expect(session.edit(delete: 1, insert: "á", latency: .milliseconds(3)).first == .forwardDelete)
        session.rig.generation.store(FocusGeneration(rawValue: 2))
        let posted = session.edit(delete: 1, insert: "à", latency: .milliseconds(60), generation: 2)
        #expect(!posted.contains(.forwardDelete))
    }

    /// A click that reaches the app while the job waits in the queue (mouse downs are never held, PLT-R317) moves the
    /// caret before the job runs. The job was built before the click, so only the live epoch, read after the read
    /// timed out, shows it: no Forward Delete.
    @Test func aClickWhileTheJobWaitsMakesItsTimedOutReadAddNothingPLTR317() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("ab")
        #expect(session.edit(delete: 1, insert: "b", latency: .milliseconds(3)).first == .forwardDelete)
        let posted = session.edit(delete: 1, insert: "b", latency: .milliseconds(60)) {
            session.rig.queue.breakCaretContinuity()
            session.field.click(at: 1)
        }
        #expect(!posted.contains(.forwardDelete))
        #expect(session.field.text == "bb")  // the "b" after the caret is still there
    }

    /// The trace's Command+A: the select-all chord breaks the continuity, so the first edit after it may not reuse the
    /// answer read before it, even though typing over the selection leaves the caret at the end. Its own read must
    /// answer (27.2 ms in the trace); when it does not, nothing is added.
    @Test func theFirstReadAfterSelectAllMustAnswerItselfPLTR423() {
        let session = SpotlightSession()
        session.type("tie")
        #expect(session.edit(delete: 1, insert: "ê", latency: .microseconds(14_600)).first == .forwardDelete)
        session.selectAll()
        session.type("vie")
        let posted = session.edit(delete: 1, insert: "ê", latency: .milliseconds(60))
        #expect(!posted.contains(.forwardDelete))
        #expect(session.rig.healthKinds() == [.fallbackActivated])
    }

    /// A fresh answer always wins: a read that finds the caret before the end (here the app moved it without any input
    /// the tap could see) adds nothing and forgets the earlier answer, so the next read that does not answer adds
    /// nothing either.
    @Test func aFreshAnswerBeforeTheEndWinsAndForgetsPLTR423() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("abc")
        #expect(session.edit(delete: 1, insert: "c", latency: .milliseconds(3)).first == .forwardDelete)
        session.field.click(at: 2)
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(3)).contains(.forwardDelete))
        session.field.click(at: 3)
        #expect(!session.edit(delete: 1, insert: "c", latency: .milliseconds(60)).contains(.forwardDelete))
    }

    /// An answer is remembered only for a job built in the epoch it read in: a click between the key and the read may
    /// not be applied by the app yet when the read answers (residual risk (a) of PLT-R423), so that answer serves its
    /// own job but no later one.
    @Test func anAnswerReadAfterABreakIsNotRememberedForLaterJobsPLTR423() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("ab")
        let stale = session.rig.queue.caretEpoch
        session.rig.queue.breakCaretContinuity()
        #expect(
            session.edit(delete: 1, insert: "b", latency: .milliseconds(3), caretEpoch: stale).first == .forwardDelete)
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(60)).contains(.forwardDelete))
    }

    /// A selected suggestion gets PLT-R420's extra Backspace and is not an answer about the end of the text: the next
    /// read that does not answer adds nothing.
    @Test func aSelectedAnswerIsNotKeptPLTR420() {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
        let session = SpotlightSession(field: field)
        session.type("a")
        let selected = session.edit(delete: 1, insert: "á", latency: .milliseconds(3))
        #expect(selected.backspaces == 2 && !selected.contains(.forwardDelete))
        #expect(!session.edit(delete: 1, insert: "à", latency: .milliseconds(60)).contains(.forwardDelete))
    }

    /// `axSelection` keeps its 15 ms bound and never keeps an answer: whether a suggestion is selected changes with
    /// every key, and an extra Backspace without a selection deletes a letter.
    @Test func axSelectionNeverKeepsAnAnswerPLTR420() {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
        let session = SpotlightSession(field: field)
        let plan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = .axSelection })
        session.type("a")
        #expect(session.edit(delete: 1, insert: "á", latency: .milliseconds(10), plan: plan).backspaces == 2)
        let started = session.rig.clock.now()
        #expect(session.edit(delete: 1, insert: "à", latency: .milliseconds(20), plan: plan).backspaces == 1)
        #expect(session.rig.clock.now().duration(since: started) == .milliseconds(15))
        #expect(session.rig.healthKinds() == [.fallbackActivated])
    }

    /// An edit that was not applied as computed (here a re-entry check that found other text, PLT-R342) leaves the
    /// field unlike what the engine believes, so the answer is forgotten.
    @Test func anEditThatPassedThroughForgetsTheAnswerPLTR423() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("ab")
        #expect(session.edit(delete: 1, insert: "b", latency: .milliseconds(3)).first == .forwardDelete)
        session.rig.fieldAccess.setReadLatency(nil, clock: session.rig.clock)
        let epoch = session.rig.queue.caretEpoch
        let mismatch = session.rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "z", insertion: "ź", plan: forwardDeletePlan,
                verifyBeforeApply: true, caretEpoch: epoch)
        }
        session.rig.run()
        #expect(session.rig.outcome(mismatch) == .passedThroughByFallback)
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(60)).contains(.forwardDelete))
    }

    /// Only a read that timed out keeps an answer. A read that fails at once (`.unavailable` for an element that is
    /// gone, `.failed` for any other AX error) says the field is not the one that answered: something the tap cannot
    /// see closed or replaced it, and focus may now be in another element before the new generation is published
    /// (PLT-R316). Nothing is added (PLT-R407), the PLT-R420 health event is counted and the answer is forgotten, so a
    /// later timeout in the same session adds nothing either.
    @Test(arguments: [FakeFocusedFieldAccess.Behaviour.unavailable, .failed])
    func aReadThatFailsAtOnceKeepsNothingAndForgetsPLTR423(behaviour: FakeFocusedFieldAccess.Behaviour) {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("ab")
        #expect(session.edit(delete: 1, insert: "b", latency: .milliseconds(3)).first == .forwardDelete)
        session.rig.fieldAccess.setBehaviour(behaviour)
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(1)).contains(.forwardDelete))
        #expect(session.rig.healthKinds().contains(.fallbackActivated))
        session.rig.fieldAccess.setBehaviour(.normal)
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(60)).contains(.forwardDelete))
        #expect(session.field.text == "ab")
    }

    /// A liveness flush (PLT-R314) resets the composition: the answer is forgotten.
    @Test func aFlushForgetsTheAnswerPLTR314() {
        let session = SpotlightSession(field: SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: [])))
        session.type("ab")
        #expect(session.edit(delete: 1, insert: "b", latency: .milliseconds(3)).first == .forwardDelete)
        session.rig.worker.requestFlush(.tapDisabled)
        session.rig.run()
        #expect(!session.edit(delete: 1, insert: "b", latency: .milliseconds(60)).contains(.forwardDelete))
    }
}

/// The worker's memory on its own: which job may keep which answer.
@Suite struct CaretAtEndMemoryTests {
    private static func job(field: FieldHandle? = Fixture.field, generation: UInt64 = 1, epoch: UInt64 = 3) -> EditJob {
        Fixture.job(deleteCount: 1, insertion: "a", generation: generation, field: field, caretEpoch: epoch)
    }

    private static let answered = Fixture.start

    /// Kept by the jobs of the same field, generation and epoch, counting the decisions and the answer's age.
    @Test func anAnswerIsKeptWithItsOriginPLTR423() {
        var memory = CaretAtEndMemory()
        memory.remember(Self.job(), epochBeforeRead: 3, answeredAt: Self.answered)
        let first = memory.keep(for: Self.job(), liveEpoch: 3, now: Self.answered.advanced(byMicroseconds: 40_000))
        #expect(first == CaretAtEndMemory.Kept(jobsSinceRead: 1, readAge: .milliseconds(40)))
        let second = memory.keep(for: Self.job(), liveEpoch: 3, now: Self.answered.advanced(byMicroseconds: 90_000))
        #expect(second == CaretAtEndMemory.Kept(jobsSinceRead: 2, readAge: .milliseconds(90)))
    }

    /// Another field (token or process), another generation, a job built in another epoch or a live epoch that moved:
    /// nothing is kept, and the answer is gone for good.
    @Test(
        arguments: [
            ("other field token", FieldHandle(pid: 42, token: 8, element: nil), UInt64(1), UInt64(3), UInt64(3)),
            ("other process", FieldHandle(pid: 43, token: 7, element: nil), 1, 3, 3),
            ("no field", nil, 1, 3, 3),
            ("other generation", Fixture.field, 2, 3, 3),
            ("job built after a break", Fixture.field, 1, 4, 4),
            ("break while the job waited", Fixture.field, 1, 3, 4),
        ] as [(String, FieldHandle?, UInt64, UInt64, UInt64)])
    func anythingElseKeepsNothingPLTR423(
        _ name: String, field: FieldHandle?, generation: UInt64, jobEpoch: UInt64, liveEpoch: UInt64
    ) {
        var memory = CaretAtEndMemory()
        memory.remember(Self.job(), epochBeforeRead: 3, answeredAt: Self.answered)
        let other = Self.job(field: field, generation: generation, epoch: jobEpoch)
        #expect(memory.keep(for: other, liveEpoch: liveEpoch, now: Self.answered) == nil, "\(name)")
        #expect(memory.keep(for: Self.job(), liveEpoch: 3, now: Self.answered) == nil, "\(name): forgotten")
    }

    /// Residual risk (a) of PLT-R423: an answer read for a job built before a break serves that job only.
    @Test func anAnswerForAJobBuiltBeforeABreakIsNotRememberedPLTR423() {
        var memory = CaretAtEndMemory()
        memory.remember(Self.job(epoch: 2), epochBeforeRead: 3, answeredAt: Self.answered)
        #expect(memory.keep(for: Self.job(), liveEpoch: 3, now: Self.answered) == nil)
    }

    @Test func forgetDropsTheAnswerPLTR423() {
        var memory = CaretAtEndMemory()
        memory.remember(Self.job(), epochBeforeRead: 3, answeredAt: Self.answered)
        memory.forget()
        #expect(memory.keep(for: Self.job(), liveEpoch: 3, now: Self.answered) == nil)
    }
}
