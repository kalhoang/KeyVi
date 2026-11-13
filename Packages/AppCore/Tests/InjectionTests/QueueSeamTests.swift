// SPDX-License-Identifier: GPL-3.0-or-later
//
// Skeleton seam tests (ADR 0311, ADR 0313): keep green; W1-D owns and may extend.
import AppModel
import RealtimeSupport
import Testing

@testable import Injection

private func boundary(_ queue: JobQueue) -> (JobSequence, InjectionJob) {
    let sequence = queue.nextSequence()
    return (
        sequence,
        .boundary(BoundaryJob(sequence: sequence, reason: .focusChanged, generation: FocusGeneration(rawValue: 1)))
    )
}

private func ms(_ value: UInt64) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: 1_000_000_000 + value * 1_000_000)
}

@Suite struct JobQueueInFlightTests {
    @Test func jobWithoutPostsSettlesWhenWorkerFinishes() {
        let queue = JobQueue(capacity: 8, signal: WorkerSignal())
        let (sequence, job) = boundary(queue)
        #expect(queue.push(job))
        #expect(queue.inFlight == 1)
        #expect(queue.pop() != nil)
        queue.finished(sequence, expectation: nil)
        #expect(queue.inFlight == 0)
    }

    /// PLT-R311 by rationale (ADR 0311): posting the final event does not end "in flight"; its echo does.
    @Test func postedJobStaysInFlightUntilEcho() {
        let queue = JobQueue(capacity: 8, signal: WorkerSignal())
        let echo = EchoTracker(queue: queue)
        let (sequence, job) = boundary(queue)
        _ = queue.push(job)
        _ = queue.pop()
        queue.finished(sequence, expectation: EchoExpectation(job: sequence, finalEventSequence: 41, postedAt: ms(0)))
        #expect(echo.settle(now: ms(1)) == .healthy)
        #expect(queue.inFlight == 1)  // a physical key arriving now is held
        echo.observed(40, at: ms(1))
        #expect(queue.inFlight == 1)
        echo.observed(41, at: ms(2))
        #expect(queue.inFlight == 0)
        #expect(echo.consecutiveMisses == 0)
    }

    @Test func echoSeenBeforeExpectationWasDrainedStillSettles() {
        let queue = JobQueue(capacity: 8, signal: WorkerSignal())
        let echo = EchoTracker(queue: queue)
        let (sequence, job) = boundary(queue)
        _ = queue.push(job)
        _ = queue.pop()
        echo.observed(7, at: ms(0))  // echo overtook the worker's expectation push
        queue.finished(sequence, expectation: EchoExpectation(job: sequence, finalEventSequence: 7, postedAt: ms(0)))
        _ = echo.settle(now: ms(0))
        #expect(queue.inFlight == 0)
    }

    @Test func threeTimeoutsInARowMeanPostingBroken() {
        let queue = JobQueue(capacity: 8, signal: WorkerSignal())
        let echo = EchoTracker(queue: queue, timeout: .milliseconds(200), missesForBroken: 3)
        for index in 0..<3 {
            let (sequence, job) = boundary(queue)
            _ = queue.push(job)
            _ = queue.pop()
            queue.finished(
                sequence,
                expectation: EchoExpectation(job: sequence, finalEventSequence: UInt32(index), postedAt: ms(0)))
        }
        #expect(echo.settle(now: ms(199)) == .healthy)
        #expect(queue.inFlight == 3)
        #expect(echo.settle(now: ms(201)) == .postingBroken)
        #expect(queue.inFlight == 0)  // timed-out jobs stop holding keys
        #expect(echo.consecutiveMisses == 3)
    }

    @Test func untilPostedPolicySettlesImmediately() {
        let queue = JobQueue(capacity: 8, signal: WorkerSignal(), policy: .untilPosted)
        let (sequence, job) = boundary(queue)
        _ = queue.push(job)
        _ = queue.pop()
        queue.finished(sequence, expectation: EchoExpectation(job: sequence, finalEventSequence: 1, postedAt: ms(0)))
        #expect(queue.inFlight == 0)
    }

    @Test func fullQueueRejectsWithoutCounting() {
        let queue = JobQueue(capacity: 2, signal: WorkerSignal())
        #expect(queue.push(boundary(queue).1))
        #expect(queue.push(boundary(queue).1))
        #expect(!queue.push(boundary(queue).1))
        #expect(queue.inFlight == 2)
        #expect(queue.queuedCount == 2)
    }

    @Test func wrappingSequenceComparison() {
        #expect(EchoTracker.isAtOrBefore(EventMarker.sequenceMask, 2))
        #expect(!EchoTracker.isAtOrBefore(2, EventMarker.sequenceMask))
        #expect(EchoTracker.isAtOrBefore(5, 5))
    }
}

@Suite struct WorkerFeedbackTests {
    @Test func outcomeBoardKeepsRecentSequences() {
        let feedback = WorkerFeedback()
        feedback.record(.executed, for: JobSequence(rawValue: 3))
        feedback.record(.abandoned, for: JobSequence(rawValue: 67))  // same slot as 3
        #expect(feedback.outcome(of: JobSequence(rawValue: 3)) == nil)
        #expect(feedback.outcome(of: JobSequence(rawValue: 67)) == .abandoned)
        #expect(feedback.outcome(of: JobSequence(rawValue: 4)) == nil)
    }

    @Test func postingBrokenFlagAndResetCounter() {
        let feedback = WorkerFeedback()
        #expect(!feedback.isPostingBroken)
        feedback.markPostingBroken()
        #expect(feedback.isPostingBroken)
        feedback.clearPostingBroken()
        #expect(!feedback.isPostingBroken)
        feedback.requestCompositionReset()
        #expect(feedback.compositionResetCount == 1)
    }
}

@Suite struct EventMarkerTests {
    @Test func roundTripAndForeign() {
        let marker = EventMarker(tag: 0xAB_CDEF_0123)
        #expect(marker.classify(marker.userData(sequence: 5, probe: false)) == .echo(sequence: 5))
        #expect(marker.classify(marker.userData(sequence: 9, probe: true)) == .probe(sequence: 9))
        #expect(marker.classify(0) == .foreign)  // physical events usually carry 0
        let other = EventMarker(tag: 0x12_3456_789A)
        #expect(marker.classify(other.userData(sequence: 5, probe: false)) == .foreign)
        #expect(
            marker.classify(marker.userData(sequence: EventMarker.sequenceMask + 3, probe: false)) == .echo(sequence: 2)
        )
    }

    @Test func randomTagsAreNonZeroAnd40Bits() {
        for _ in 0..<100 {
            let marker = EventMarker.random()
            #expect(marker.tag != 0)
            #expect(marker.tag <= EventMarker.tagMask)
        }
    }

    @Test func currentFocusGeneration() {
        let generation = CurrentFocusGeneration()
        generation.store(FocusGeneration(rawValue: 9))
        #expect(generation.load() == FocusGeneration(rawValue: 9))
    }
}
