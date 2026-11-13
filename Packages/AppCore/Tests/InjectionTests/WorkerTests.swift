// SPDX-License-Identifier: LicenseRef-App-Pending
//
// InjectionWorker in step mode (`runUntilIdle`, ManualClock): FIFO, held replays, generation discard, liveness,
// paired keyUps, one `finished` per job, posting broken (PLT-R311-R316, ADR 0308, ADR 0311).

import AppModel
import Diagnostics
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private func key(_ character: Character, at offsetMs: UInt64 = 0, keyboardType: UInt32 = 40) -> KeyEventRecord {
    InjectionFieldWiring.keyDown(
        character, receivedAt: MonotonicInstant(nanoseconds: Fixture.start.nanoseconds + offsetMs * 1_000_000),
        keyboardType: keyboardType)
}

@Suite struct WorkerOrderingTests {
    /// 4.10 acceptance through the worker: the minimizer runs before `backspaceReplace` (PLT-R402).
    @Test func nguyenPlusSThroughTheWorkerPLTR402() {
        let rig = WorkerRig(field: SimulatedTextField(text: "nguyen"))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 6, replaced: "nguyen", insertion: "nguyến") }
        rig.run()
        #expect(rig.poster.posted.backspaceCount == 2)
        #expect(rig.poster.posted.keyDowns.filter { $0.keyCode != .delete }.count == 2)
        #expect(rig.field.text == "nguyến")
    }

    /// PLT-R311: strict FIFO; held events are replayed once each, in order, after the edit before them.
    @Test func heldEventsAreReplayedOnceInOrderPLTR311() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.pushReplay(key("b"))
        rig.pushReplay(InjectionFieldWiring.keyUp(key("b")))
        rig.pushReplay(key("c"))
        rig.run()
        #expect(rig.field.text == "ábc")
        let order = rig.poster.posted.map { $0.replayed.map { "\($0.kind)-\($0.unicode.string)" } ?? "edit" }
        #expect(order == ["edit", "edit", "edit", "edit", "keyDown-b", "keyUp-b", "keyDown-c"])
        #expect(rig.outcome(edit) == .executed)
    }

    /// PLT-R321/R324: every posted event carries the marker with a fresh sequence, replays keep their fields.
    @Test func everyEventIsMarkedWithAFreshSequencePLTR321() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        var probe = key("x", keyboardType: 59)
        probe.isProbe = true
        rig.pushReplay(probe)
        rig.run()
        let matches = rig.poster.posted.map { rig.marker.classify($0.userData) }
        #expect(matches == (0..<5).map { MarkerMatch.echo(sequence: UInt32($0)) })
        #expect(rig.poster.posted.last?.replayed == probe)
    }

    @Test func nfcAndExpansionCapPLTR403R480() {
        let rig = WorkerRig()
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "e\u{0302}\u{0301}") }
        let allowed = Fixture.parameters { $0.allowMultiCharEvents = true }
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 0, insertion: String(repeating: "a", count: 4_500),
                plan: Fixture.plan(parameters: allowed), kind: .macro)
        }
        rig.run()
        #expect(rig.poster.posted.keyDowns.first?.unicode.string == "\u{1EBF}")
        #expect(rig.field.text.count == 1 + 4_000)
    }
}

@Suite struct WorkerAbandonTests {
    /// PLT-R316 + ADR 0308: a stale edit is discarded, its trigger replayed, the composition reset.
    @Test func staleGenerationIsDiscardedAndItsTriggerReplayedPLTR316() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let stale = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", generation: 1) }
        rig.pushReplay(key("b"))
        rig.generation.store(FocusGeneration(rawValue: 2))
        let current = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "ư", generation: 2) }
        rig.run()
        #expect(rig.field.text == "asbư")
        #expect(rig.outcome(stale) == .discardedForGeneration)
        #expect(rig.outcome(current) == .executed)
        #expect(rig.feedback.compositionResetCount == 1)
        #expect(rig.healthKinds() == [.generationDiscard])
    }

    /// PLT-R314: the oldest held event waited more than 150 ms: unstarted edits are abandoned (triggers
    /// replayed), held events replayed in order, composition reset, one `flush` health event.
    @Test func livenessCeilingFlushesAfter150msPLTR314() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.pushReplay(key("b"))
        rig.clock.advance(byMicroseconds: 150_001)
        rig.run()
        #expect(rig.field.text == "asb")
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.metrics.flushes.value == 1)
        #expect(rig.feedback.compositionResetCount == 1)
        let flush = rig.health.recent(limit: 10).first { $0.kind == .flush }
        #expect(flush?.detail == .count(1))
    }

    @Test func noFlushAtExactly150ms() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.clock.advance(byMicroseconds: 150_000)
        rig.run()
        #expect(rig.field.text == "á")
        #expect(rig.metrics.flushes.value == 0)
    }

    /// PLT-R314: a running (paced) job completes; only the edits that had not started are abandoned.
    @Test func flushAbandonsOnlyUnstartedEdits() {
        let rig = WorkerRig(field: SimulatedTextField(text: "ab"))
        let paced = Fixture.parameters {
            $0.interEventDelayUs = 40_000
            $0.postDeleteSettleUs = 30_000
        }
        let running = rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 2, insertion: "ăb", plan: Fixture.plan(parameters: paced))
        }
        let waiting = rig.pushEdit {
            Fixture.job(sequence: $0, deleteCount: 1, insertion: "ư", trigger: key("w"))
        }
        rig.pushReplay(key("c"))
        rig.clock.advance(byMicroseconds: 10_000)
        rig.run()
        // The paced job took 150 ms after a 10 ms wait, so the next edit's key waited 160 ms.
        #expect(rig.outcome(running) == .executed)
        #expect(rig.outcome(waiting) == .abandoned)
        #expect(rig.field.text == "ăbwc")
        #expect(rig.metrics.flushes.value == 1)
    }

    /// PLT-R480: right after a macro the ceiling is 1 s.
    @Test func macroLivenessCeilingIsOneSecondPLTR480() {
        let rig = WorkerRig()
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "cảm ơn", kind: .macro) }
        rig.run()
        rig.pushReplay(key("a", at: 0))
        rig.clock.advance(byMicroseconds: 900_000)
        rig.run()
        #expect(rig.metrics.flushes.value == 0)
        rig.pushReplay(key("b", at: 900))
        rig.clock.advance(byMicroseconds: 1_000_001)
        rig.run()
        #expect(rig.metrics.flushes.value == 1)
        #expect(rig.field.text == "cảm ơnab")
    }

    /// PLT-R314: more than 256 queued jobs force a flush.
    @Test func moreThan256QueuedJobsFlushPLTR314() {
        let rig = WorkerRig()
        let first = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "ư", trigger: key("w")) }
        for _ in 0..<256 { rig.pushReplay(key("a")) }
        rig.run()
        #expect(rig.outcome(first) == .abandoned)
        #expect(rig.metrics.flushes.value == 1)
        #expect(rig.field.text == "w" + String(repeating: "a", count: 256))
        #expect(rig.queue.inFlight == 257)
    }

    @Test func requestFlushIsHonouredOnTheNextRun() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.worker.requestFlush(.tapDisabled)
        rig.run()
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.field.text == "as")
        rig.worker.requestFlush(.failOpen)
        rig.run()
        #expect(rig.metrics.flushes.value == 2)
        rig.worker.requestFlush(.queueFull)
        rig.run()
        #expect(rig.logger.entries.count == 1)
    }
}

@Suite struct WorkerPairingTests {
    /// PLT-R313 / ADR 0308: the keyUp of an executed edit's trigger is dropped.
    @Test func pairedKeyUpIsDroppedAfterExecution() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(Fixture.triggerS), forJob: edit)
        rig.run()
        #expect(rig.poster.posted.compactMap(\.replayed).isEmpty)
        let expectations = rig.drainExpectations()
        #expect(expectations.map(\.job.rawValue) == [edit])
        #expect(rig.queue.inFlight == 0)
    }

    @Test func pairedKeyUpIsReplayedAfterAbandonment() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", generation: 0) }
        let keyUp = InjectionFieldWiring.keyUp(Fixture.triggerS)
        rig.pushPairedKeyUp(keyUp, forJob: edit)
        rig.run()
        #expect(rig.poster.posted.compactMap(\.replayed) == [Fixture.triggerS, keyUp])
    }

    @Test func pairedKeyUpOfAnUnknownJobIsReplayed() {
        let rig = WorkerRig()
        rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(Fixture.triggerS), forJob: 999_999)
        rig.run()
        #expect(rig.poster.posted.compactMap(\.replayed).count == 1)
    }

    /// Paste step 4 releases held events behind the running job; its paired keyUp counts as executed.
    @Test func keyUpReleasedMidJobBelongsToAnExecutedJob() {
        let pasteboard = FakePasteboard(items: [])
        let field = SimulatedTextField(text: "u", pasteboardText: { pasteboard.plainText })
        let rig = WorkerRig(field: field, pasteboard: pasteboard)
        let parameters = Fixture.parameters { $0.pasteOptedIn = true }
        let edit = rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, insertion: "ừ", plan: Fixture.plan(.paste, parameters: parameters))
        }
        rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(Fixture.triggerS), forJob: edit)
        let held = rig.pushReplay(key("b"))
        rig.run()
        #expect(rig.field.text == "ừb")
        #expect(rig.poster.posted.compactMap(\.replayed).map(\.unicode.string) == ["b"])
        let expectations = rig.drainExpectations()
        #expect(expectations.map(\.job.rawValue) == [held, edit])
        #expect(expectations[0].finalEventSequence == expectations[1].finalEventSequence)
    }
}

@Suite struct WorkerFinishedTests {
    /// ADR 0311: exactly one `finished` per job, with an expectation iff the job posted.
    @Test func expectationIffPostedADR0311() {
        let rig = WorkerRig(field: SimulatedTextField(text: "abc"))
        let boundary = rig.pushBoundary()
        let empty = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 3, replaced: "abc", insertion: "abc") }
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "ĉ") }
        let dropped = rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(Fixture.triggerS), forJob: edit)
        let replay = rig.pushReplay(key("d"))
        rig.run()
        #expect(rig.queue.inFlight == 2)  // the two posting jobs wait for their echoes
        let expectations = rig.drainExpectations()
        #expect(expectations.map(\.job.rawValue) == [edit, replay])
        let sequences = rig.poster.posted.map { rig.marker.classify($0.userData) }
        #expect(expectations.map { MarkerMatch.echo(sequence: $0.finalEventSequence) } == [sequences[3], sequences[4]])
        #expect(rig.queue.inFlight == 0)
        #expect(rig.outcome(empty) == .executed)
        #expect(![boundary, empty, dropped].contains { seq in expectations.contains { $0.job.rawValue == seq } })
    }

    /// With `InFlightPolicy.untilPosted` (ADR 0311 fallback) posted jobs settle at `finished`.
    @Test func untilPostedSettlesEveryJobAtFinish() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"), policy: .untilPosted)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.pushReplay(key("b"))
        rig.run()
        #expect(rig.queue.inFlight == 0)
        #expect(rig.queue.expectations.pop() == nil)
    }

    /// The echo tracker settles worker jobs on their echoes (the seam with the tap).
    @Test func echoesSettleWorkerJobs() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let echo = EchoTracker(queue: rig.queue)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.run()
        #expect(rig.queue.inFlight == 1)
        for posted in rig.poster.posted {
            if case .echo(let sequence) = rig.marker.classify(posted.userData) {
                echo.observed(sequence, at: rig.clock.now())
            }
        }
        #expect(rig.queue.inFlight == 0)
    }
}

@Suite struct WorkerPostingBrokenTests {
    /// ADR 0311 / ADR 0308 amendment: once posting is broken nothing more is posted, every undeliverable event
    /// is counted, and one `postingBroken` health event carries the count.
    @Test func postingBrokenPostsNothingAndCountsLossesADR0311() {
        let rig = WorkerRig(field: SimulatedTextField(text: "a"))
        let executed = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        rig.run()
        _ = rig.drainExpectations()
        let postedBefore = rig.poster.posted.count
        rig.poster.setMode(.silentlyDropping)
        rig.feedback.markPostingBroken()
        rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(Fixture.triggerS), forJob: executed)  // consumed, not lost
        let edit = rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "ả", trigger: key("r")) }
        rig.pushPairedKeyUp(InjectionFieldWiring.keyUp(key("r")), forJob: edit)  // its keyDown was not delivered
        rig.pushReplay(key("b"))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 0, insertion: "ư", trigger: nil) }  // thenPassThrough
        rig.run()
        #expect(rig.poster.posted.count == postedBefore)
        #expect(rig.poster.dropped.isEmpty)
        #expect(rig.metrics.lostWhilePostingBroken.value == 3)
        let broken = rig.health.recent(limit: 10).filter { $0.kind == .postingBroken }
        #expect(broken.map(\.detail) == [.count(3)])
        #expect(rig.outcome(edit) == .abandoned)
        #expect(rig.queue.inFlight == 0)  // nothing posted: every job settled by the worker
    }

    @Test func flushWhilePostingBrokenCountsHeldEvents() {
        let rig = WorkerRig()
        rig.feedback.markPostingBroken()
        rig.pushReplay(key("a"))
        rig.pushReplay(key("b"))
        rig.worker.requestFlush(.failOpen)
        rig.run()
        #expect(rig.metrics.lostWhilePostingBroken.value == 2)
        #expect(rig.poster.posted.isEmpty)
    }

    @Test func eventCreationFailureIsLoggedNotLost() {
        let rig = WorkerRig()
        rig.poster.setMode(.failingCreation)
        rig.pushReplay(key("a"))
        rig.run()
        #expect(rig.logger.entries.count == 1)
        #expect(rig.metrics.lostWhilePostingBroken.value == 0)
        #expect(rig.queue.inFlight == 0)
    }
}
