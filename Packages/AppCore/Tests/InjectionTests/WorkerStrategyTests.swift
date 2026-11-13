// SPDX-License-Identifier: GPL-3.0-or-later
//
// Worker-level strategy behaviour: fallback chain and focus-session degradation (4.5, PLT-R410), re-entry
// verification (PLT-R342), verifyAfterEdit readback (PLT-R410, PLT-R422), long text (PLT-R460, PLT-R480),
// first-edit delay (PLT-R408), metrics (8.1) and the threaded `inject` loop (PLT-R203, PLT-R315).

import AppModel
import Diagnostics
import Dispatch
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

@Suite struct WorkerFallbackTests {
    /// 4.5: an AX failure uses the fallback and degrades the field for the rest of the focus session.
    @Test func axFailureFallsBackAndDegradesTheSession() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.unavailable)
        let plan = Fixture.plan(.axReplace, fallback: [.backspaceReplace])
        let first = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.run()
        #expect(rig.outcome(first) == .executedWithFallback)
        #expect(rig.field.text == "á")
        let callsAfterFirst = rig.fieldAccess.callCount
        let second = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "b", plan: plan) }
        rig.run()
        #expect(rig.outcome(second) == .executed)  // axReplace is skipped, the fallback is now first
        #expect(rig.fieldAccess.callCount == callsAfterFirst)
        #expect(rig.metrics.fallbackActivations.value == 1)
        #expect(rig.health.recent(limit: 10).map(\.detail) == [.fallback(from: .axReplace, to: .backspaceReplace)])
        // A new focus generation forgets the degradation.
        rig.generation.store(FocusGeneration(rawValue: 2))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "c", plan: plan, generation: 2) }
        rig.run()
        #expect(rig.fieldAccess.callCount > callsAfterFirst)
    }

    @Test func readbackMismatchAfterWritingKeepsTheOutput() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.writesIgnored)
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, insertion: "á",
                plan: Fixture.plan(.axReplace, fallback: [.backspaceReplace]))
        }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.poster.posted.isEmpty)  // never applied twice
        #expect(rig.feedback.compositionResetCount == 1)
    }

    /// 4.5, PLT-R312: the field applied the selection but silently ignored the text write. Nothing changed,
    /// so the caret is put back and the fallback delivers the edit; the word stays and nothing is lost.
    @Test func ignoredTextWriteRestoresTheCaretAndUsesTheFallback() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.textWritesIgnored)
        let plan = Fixture.plan(.axReplace, fallback: [.backspaceReplace])
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "á")
        #expect(rig.field.selection == Injection.TextRange(location: 1, length: 0))
        #expect(rig.feedback.compositionResetCount == 0)
        // The field keeps the fallback for the rest of the focus session (4.5).
        let calls = rig.fieldAccess.callCount
        let next = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "b", plan: plan) }
        rig.run()
        #expect(rig.outcome(next) == .executed)
        #expect(rig.fieldAccess.callCount == calls)
        #expect(rig.field.text == "áb")
    }

    @Test func exhaustedChainPassesTheTriggerThrough() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.fieldAccess.setBehaviour(.timeout)
        let edit = rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: Fixture.plan(.axReplace, fallback: []))
        }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "as")
    }

    @Test func tooLongJobUsesTheFallbackPLTR408() {
        let rig = WorkerRig(field: SimulatedTextField(text: "abcd"))
        let slow = Fixture.parameters { $0.interEventDelayUs = 50_000 }
        let edit = rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 4, insertion: "wxyz", plan: Fixture.plan(parameters: slow))
        }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "abcds")
    }

    /// PLT-R460: `paste` is never used without the user's opt-in.
    @Test func pasteWithoutOptInIsSkipped() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, insertion: "á", plan: Fixture.plan(.paste, fallback: [.backspaceReplace]))
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.pasteboard.transientWriteCount == 0)
        #expect(rig.field.text == "á")
    }

    @Test func unsafeClipboardFallsBackPLTR461() {
        let pasteboard = FakePasteboard(items: [])
        pasteboard.set(.filePromise, true)
        let rig = WorkerRig(field: SimulatedTextField(text: "a"), pasteboard: pasteboard)
        let opted = Fixture.parameters { $0.pasteOptedIn = true }
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, insertion: "á",
                plan: Fixture.plan(.paste, parameters: opted, fallback: [.backspaceReplace]))
        }
        rig.run()
        #expect(rig.outcome(edit) == .executedWithFallback)
        #expect(rig.field.text == "á")
        #expect(rig.health.recent(limit: 10).map(\.detail) == [.fallback(from: .paste, to: .backspaceReplace)])
    }

    /// PLT-R480: over 2,000 graphemes with the opt-in, `paste` goes first; the clipboard is restored later.
    @Test func longTextUsesPasteWhenOptedInPLTR480() {
        let saved = [
            PasteboardItemData(types: ["public.utf8-plain-text"], data: ["public.utf8-plain-text": Data("old".utf8)])
        ]
        let pasteboard = FakePasteboard(items: saved)
        let field = SimulatedTextField(pasteboardText: { pasteboard.plainText })
        let rig = WorkerRig(field: field, pasteboard: pasteboard)
        let text = String(repeating: "ơ", count: 2_001)
        let opted = Fixture.parameters { $0.pasteOptedIn = true }
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 0, insertion: text, plan: Fixture.plan(parameters: opted), kind: .macro)
        }
        rig.run()
        #expect(rig.field.text == text)
        #expect(rig.poster.posted.keyDowns.count == 1)
        #expect(pasteboard.items == saved)
        #expect(rig.clock.now().nanoseconds == Fixture.start.nanoseconds + 400_000_000)
    }

    @Test func userCopyDuringTheRestoreWindowIsKept() {
        let pasteboard = FakePasteboard(items: [])
        let copied = PasteboardItemData(
            types: ["public.utf8-plain-text"], data: ["public.utf8-plain-text": Data("mine".utf8)])
        let field = SimulatedTextField(pasteboardText: { pasteboard.plainText })
        let layout = InjectionTestLayouts.qwerty()
        let poster = FakeEventPoster { posted in
            guard case .synthetic(let event, _) = posted else { return }
            field.apply(event, layout: layout)
            if event.flags == SyntheticKeys.commandFlag, !event.isKeyDown { pasteboard.userCopies(copied) }
        }
        let rig = WorkerRig(field: field, pasteboard: pasteboard, poster: poster)
        let opted = Fixture.parameters { $0.pasteOptedIn = true }
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 0, insertion: "x", plan: Fixture.plan(.paste, parameters: opted))
        }
        rig.run()
        #expect(pasteboard.items == [copied])
        #expect(rig.healthKinds() == [.pasteRestoreSkipped])
    }
}

@Suite struct WorkerVerificationTests {
    /// PLT-R342: the word before the caret still matches: the edit applies.
    @Test func reentryAppliesWhenTheWordMatchesPLTR342() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chao"))
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 2, replaced: "chao", insertion: "ào", kind: .reentry, verifyBeforeApply: true
            )
        }
        rig.run()
        #expect(rig.outcome(edit) == .executed)
        #expect(rig.field.text == "xin chào")
    }

    /// PLT-R342: autocorrect changed the word: history dropped, the key passes through.
    @Test func reentryMismatchPassesTheKeyThroughPLTR342() {
        let rig = WorkerRig(field: SimulatedTextField(text: "xin chap"))
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 2, replaced: "chao", insertion: "ào", kind: .reentry, verifyBeforeApply: true
            )
        }
        rig.run()
        #expect(rig.outcome(edit) == .passedThroughByFallback)
        #expect(rig.field.text == "xin chaps")
        #expect(rig.feedback.compositionResetCount == 1)
    }

    @Test func reentryEdgeCases() {
        let short = WorkerRig(field: SimulatedTextField(text: "ao"))
        let tooShort = short.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "chao", insertion: "ó", kind: .reentry, verifyBeforeApply: true)
        }
        short.run()
        #expect(short.outcome(tooShort) == .passedThroughByFallback)
        let unreadable = WorkerRig(field: SimulatedTextField(text: "chao"))
        unreadable.fieldAccess.setBehaviour(.unavailable)
        let applied = unreadable.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, replaced: "chao", insertion: "ó", kind: .reentry, verifyBeforeApply: true)
        }
        unreadable.run()
        #expect(unreadable.outcome(applied) == .executed)  // `whenReadable`
    }

    /// PLT-R410: `verifyAfterEdit` reads the written range back after the job; a match changes nothing.
    @Test func verifyAfterEditMatchRecordsNothing() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let verify = Fixture.parameters { $0.verifyAfterEdit = true }
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: Fixture.plan(parameters: verify))
        }
        rig.run()
        #expect(rig.health.recent(limit: 10).isEmpty)
        #expect(rig.metrics.decideToPostedWithAX.snapshot().count == 1)
    }

    /// PLT-R410 / PLT-R422: dropped backspaces leave the placeholder behind; both problems are reported and the
    /// field uses the fallback for the rest of the session.
    @Test func verifyAfterEditReportsResidueAndMismatchPLTR422() {
        let field = SimulatedTextField(text: "ab")
        let layout = InjectionTestLayouts.qwerty()
        let poster = FakeEventPoster { posted in
            guard case .synthetic(let event, _) = posted, event.keyCode != .delete else { return }
            field.apply(event, layout: layout)
        }
        let rig = WorkerRig(field: field, poster: poster)
        let parameters = Fixture.parameters {
            $0.verifyAfterEdit = true
            $0.inlineCompletion = .placeholder
        }
        let plan = Fixture.plan(parameters: parameters, fallback: [.selectReplace])
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "x", plan: plan) }
        rig.run()
        #expect(field.text == "ab\u{200B}x")
        #expect(Set(rig.healthKinds()) == [.placeholderResidue, .fallbackActivated])
        let next = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "y", plan: plan) }
        rig.run()
        #expect(rig.outcome(next) == .executed)
        #expect(rig.poster.posted.keyDowns.last?.unicode.string == "y")
    }

    @Test func aNewEditSupersedesAPendingReadback() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let verify = Fixture.parameters { $0.verifyAfterEdit = true }
        rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: Fixture.plan(parameters: verify))
        }
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "b") }
        rig.run()
        #expect(rig.health.recent(limit: 10).isEmpty)
        #expect(rig.clock.now() == Fixture.start)
    }
}

@Suite struct WorkerTimingAndMetricsTests {
    /// PLT-R408: the first-edit delay applies to the first edit of a flagged word only, again after a boundary.
    @Test func firstEditDelayAppliesOncePerWordPLTR408() {
        let rig = WorkerRig()
        let delayed = Fixture.parameters { $0.firstEditDelayUs = 20_000 }
        let plan = Fixture.plan(parameters: delayed)
        func push(_ text: String) {
            rig.pushEdit {
                Fixture.job(sequence: $0, deleteCount: 0, insertion: text, plan: plan, nearFocusChange: true)
            }
        }
        push("a")
        rig.run()
        #expect(rig.clock.now().nanoseconds == Fixture.start.nanoseconds + 20_000_000)
        push("b")
        rig.run()
        #expect(rig.clock.now().nanoseconds == Fixture.start.nanoseconds + 20_000_000)
        rig.pushBoundary(.mouseDown)
        push("c")
        rig.run()
        #expect(rig.clock.now().nanoseconds == Fixture.start.nanoseconds + 40_000_000)
    }

    /// 8.1: T2 for user edits, T3 when AX was used, probe T2 for latency-probe jobs, T5 for held events.
    @Test func latencyMetricsAreRoutedPerKind() {
        let rig = WorkerRig(field: SimulatedTextField(text: "ab"))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "ḃ") }
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "c", isProbe: true) }
        let axPlan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = .axSelection })
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "ĉ", plan: axPlan) }
        rig.pushReplay(InjectionFieldWiring.keyDown("d", receivedAt: Fixture.start))
        var probe = InjectionFieldWiring.keyDown("e", receivedAt: Fixture.start)
        probe.isProbe = true
        rig.pushReplay(probe)
        rig.run()
        #expect(rig.metrics.decideToPosted.snapshot().count == 1)
        #expect(rig.metrics.probeDecideToPosted.snapshot().count == 1)
        #expect(rig.metrics.decideToPostedWithAX.snapshot().count == 1)
        #expect(rig.metrics.heldWait.snapshot().count == 1)
    }
}

@Suite(.serialized) struct WorkerThreadTests {
    /// PLT-R203 / PLT-R315: the `inject` thread drains jobs pushed from another thread and waits only on its own
    /// signal. Uses the real clock and no deadlines, so nothing sleeps for a fixed time.
    @Test func threadDrainsJobsPushedFromAnotherThread() {
        let delivered = DispatchSemaphore(value: 0)
        let poster = FakeEventPoster { _ in delivered.signal() }
        let signal = WorkerSignal()
        let queue = JobQueue(capacity: 64, signal: signal)
        let feedback = WorkerFeedback()
        let services = InjectionServices(
            poster: poster, fieldAccess: FakeFocusedFieldAccess(field: SimulatedTextField()),
            pasteboard: FakePasteboard(),
            clock: MachClock(), metrics: PlatformMetrics(), health: HealthEventLog(), logger: RecordingLogger(),
            capture: nil)
        let generation = CurrentFocusGeneration()
        let worker = InjectionWorker(
            queue: queue, signal: signal, feedback: feedback, marker: EventMarker(tag: 0x55),
            focusGeneration: generation,
            services: services)
        worker.start()
        worker.start()  // idempotent
        let now = MachClock().now()
        for character in "abc" {
            let record = InjectionFieldWiring.keyDown(character, receivedAt: now)
            #expect(queue.push(.replay(queue.nextSequence(), record)))
        }
        for _ in 0..<3 { #expect(delivered.wait(timeout: .now() + .seconds(10)) == .success) }
        worker.requestFlush(.tapDisabled)
        #expect(queue.push(.replay(queue.nextSequence(), InjectionFieldWiring.keyDown("d", receivedAt: now))))
        #expect(delivered.wait(timeout: .now() + .seconds(10)) == .success)
        worker.stop()
        worker.stop()  // idempotent
        #expect(poster.posted.count == 4)
        #expect(feedback.compositionResetCount >= 1)
    }

    @Test func threadServicesARestoreDeadline() {
        let restored = DispatchSemaphore(value: 0)
        let pasteboard = RestoreSignallingPasteboard(onRestore: { restored.signal() })
        let signal = WorkerSignal()
        let queue = JobQueue(capacity: 64, signal: signal)
        let services = InjectionServices(
            poster: FakeEventPoster(), fieldAccess: FakeFocusedFieldAccess(field: SimulatedTextField()),
            pasteboard: pasteboard,
            clock: MachClock(), metrics: PlatformMetrics(), health: HealthEventLog(), logger: RecordingLogger(),
            capture: nil)
        var configuration = WorkerConfiguration()
        configuration.livenessCeiling = .seconds(10)  // a loaded machine must not turn this into a flush test
        let worker = InjectionWorker(
            queue: queue, signal: signal, feedback: WorkerFeedback(), marker: EventMarker(tag: 0x56),
            focusGeneration: CurrentFocusGeneration(), services: services, configuration: configuration)
        worker.start()
        defer { worker.stop() }
        let parameters = Fixture.parameters {
            $0.pasteOptedIn = true
            $0.restoreDelayMs = 1
        }
        let now = MachClock().now()
        let job = Fixture.job(
            sequence: queue.nextSequence().rawValue, deleteCount: 0, insertion: "x",
            plan: Fixture.plan(.paste, parameters: parameters),
            generation: 0, trigger: InjectionFieldWiring.keyDown("s", receivedAt: now), createdAt: now)
        #expect(queue.push(.edit(job)))
        #expect(restored.wait(timeout: .now() + .seconds(10)) == .success)
    }
}

/// `FakePasteboard` that signals when a restore happens (threaded deadline test).
private final class RestoreSignallingPasteboard: PasteboardAccess, Sendable {
    private let base = FakePasteboard(items: [])
    private let onRestore: @Sendable () -> Void
    init(onRestore: @escaping @Sendable () -> Void) { self.onRestore = onRestore }
    var changeCount: Int { base.changeCount }
    func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        try base.snapshot(limits: limits)
    }
    func writeTransient(_ text: String) throws(PasteboardError) -> Int { try base.writeTransient(text) }
    func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) {
        try base.restore(snapshot)
        onRestore()
    }
}
