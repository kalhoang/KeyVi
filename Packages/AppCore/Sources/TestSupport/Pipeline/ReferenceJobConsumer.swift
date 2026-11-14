// SPDX-License-Identifier: GPL-3.0-or-later
//
// The reference job consumer of the W1-F1 property suite: a deterministic, single-threaded stand-in for the
// inject worker with the behaviours conservation depends on (PLT-R311, PLT-R314, PLT-R316, PLT-R323, ADR 0308,
// ADR 0311). It posts edits as backspace pairs plus one pair per grapheme, replays held events, resolves paired
// keyUps, discards stale edits, flushes on the liveness ceiling, publishes echo expectations, and counts what
// it cannot deliver once posting broke. W2-A runs the same suite with the real `InjectionWorker`.
//
// Loss accounting: the real worker sees only `WorkerFeedback.isPostingBroken`. This consumer also knows when
// the fake poster drops silently, so it counts posts into the void as losses; that is the accounting the
// "losses equal the metric" check needs (W1-D note in the W1-F1 report).

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport

final class ReferenceJobConsumer {
    enum Delivery {
        case edit(event: Int?, final: Bool)
        case replay(event: Int?)
    }

    static let livenessCeilingNanoseconds: UInt64 = 150_000_000  // PLT-R314
    static let maximumQueuedJobs = 256

    private let queue: JobQueue
    private let feedback: WorkerFeedback
    private let marker: EventMarker
    private let poster: FakeEventPoster
    private let focusGeneration: CurrentFocusGeneration
    private let metrics: PlatformMetrics
    private let clock: ManualClock
    /// Physical event index of a record (`receivedAt`) or an edit (`createdAt`).
    private let eventIndex: (MonotonicInstant) -> Int?
    private let onLost: (Int) -> Void
    /// Called after a job's events were posted and before its expectation is published.
    private let onPosted: () -> Void
    private var pending: [InjectionJob] = []
    private var eventSequence: UInt32 = 0
    private var outcomes: [JobSequence: JobOutcome] = [:]
    private(set) var deliveries: [UInt32: Delivery] = [:]
    private(set) var discardedEdits = 0
    /// Edits of a word begun within 300 ms of a focus change or click (PLT-R408 first-edit delay).
    private(set) var editsNearFocusChange = 0

    init(
        queue: JobQueue, feedback: WorkerFeedback, marker: EventMarker, poster: FakeEventPoster,
        focusGeneration: CurrentFocusGeneration, metrics: PlatformMetrics, clock: ManualClock,
        eventIndex: @escaping (MonotonicInstant) -> Int?, onLost: @escaping (Int) -> Void,
        onPosted: @escaping () -> Void
    ) {
        self.queue = queue
        self.feedback = feedback
        self.marker = marker
        self.poster = poster
        self.focusGeneration = focusGeneration
        self.metrics = metrics
        self.clock = clock
        self.eventIndex = eventIndex
        self.onLost = onLost
        self.onPosted = onPosted
    }

    var isIdle: Bool {
        pull()
        return pending.isEmpty
    }

    /// Executes one job (or one liveness flush). False when there was nothing to do.
    @discardableResult
    func runOne() -> Bool {
        pull()
        if needsFlush() {
            flush()
            return true
        }
        guard !pending.isEmpty else { return false }
        execute(pending.removeFirst())
        return true
    }

    func delivery(forUserData userData: Int64) -> Delivery? {
        guard case .echo(let sequence) = marker.classify(userData) else { return nil }
        return deliveries[sequence]
    }

    private func pull() {
        while let job = queue.pop() { pending.append(job) }
    }

    /// PLT-R314: the oldest held event waited too long, or too many jobs queued.
    private func needsFlush() -> Bool {
        if pending.count > Self.maximumQueuedJobs { return true }
        let now = clock.now()
        for job in pending {
            switch job {
            case .replay(_, let record), .pairedKeyUp(_, let record, _):
                return now.nanoseconds(since: record.receivedAt) > Self.livenessCeilingNanoseconds
            default: continue
            }
        }
        return false
    }

    /// Abandons every unstarted edit (replaying its trigger), replays every held event in order, asks the tap
    /// to reset the composition and counts a flush (PLT-R314, ADR 0308).
    private func flush() {
        let jobs = pending
        pending.removeAll()
        for job in jobs {
            if case .edit(let edit) = job {
                record(.abandoned, for: edit.sequence)
                finish(edit.sequence, edit.trigger.flatMap { replay($0, job: edit.sequence) })
            } else {
                execute(job)
            }
        }
        feedback.requestCompositionReset()
        metrics.flushes.increment()
    }

    private func execute(_ job: InjectionJob) {
        switch job {
        case .edit(let edit): executeEdit(edit)
        case .replay(let sequence, let held): finish(sequence, replay(held, job: sequence))
        case .pairedKeyUp(let sequence, let keyUp, let forJob):
            switch outcomes[forJob] ?? feedback.outcome(of: forJob) {
            case .executed?, .executedWithFallback?: finish(sequence, nil)  // dropped with its keyDown's edit
            default: finish(sequence, replay(keyUp, job: sequence))
            }
        case .boundary(let boundary): finish(boundary.sequence, nil)
        }
    }

    private func executeEdit(_ edit: EditJob) {
        if edit.generation < focusGeneration.load() {  // PLT-R316
            record(.discardedForGeneration, for: edit.sequence)
            discardedEdits += 1
            feedback.requestCompositionReset()
            finish(edit.sequence, edit.trigger.flatMap { replay($0, job: edit.sequence) })
            return
        }
        let index = eventIndex(edit.createdAt)
        if edit.wordStartedNearFocusChange { editsNearFocusChange += 1 }
        if feedback.isPostingBroken {  // ADR 0308 amendment: post nothing, count what is lost
            record(.abandoned, for: edit.sequence)
            if edit.trigger != nil, let index { lose(index) }
            finish(edit.sequence, nil)
            return
        }
        let dropping = poster.mode == .silentlyDropping
        var last: UInt32 = 0
        let total = edit.deleteCount * 2 + edit.insertion.count * 2
        var posted = 0
        func emit(_ event: SyntheticKeyEvent) {
            posted += 1
            last = post(event, delivery: .edit(event: index, final: posted == total))
        }
        for _ in 0..<edit.deleteCount {
            emit(SyntheticKeyEvent(keyCode: .delete, isKeyDown: true, flags: 0, unicode: .empty))
            emit(SyntheticKeyEvent(keyCode: .delete, isKeyDown: false, flags: 0, unicode: .empty))
        }
        for grapheme in edit.insertion {
            let unicode = InlineUTF16(String(grapheme)) ?? .empty
            emit(SyntheticKeyEvent(keyCode: edit.keyCodes.trigger, isKeyDown: true, flags: 0, unicode: unicode))
            emit(SyntheticKeyEvent(keyCode: edit.keyCodes.trigger, isKeyDown: false, flags: 0, unicode: unicode))
        }
        record(.executed, for: edit.sequence)
        if dropping, edit.trigger != nil, let index { lose(index) }
        finish(edit.sequence, EchoExpectation(job: edit.sequence, finalEventSequence: last, postedAt: clock.now()))
    }

    /// Replays a held event; nil expectation when nothing was posted.
    private func replay(_ held: KeyEventRecord, job: JobSequence) -> EchoExpectation? {
        let index = eventIndex(held.receivedAt)
        if feedback.isPostingBroken {
            if let index { lose(index) }
            return nil
        }
        let dropping = poster.mode == .silentlyDropping
        let sequence = nextEventSequence(.replay(event: index))
        try? poster.replay(held, userData: marker.userData(sequence: sequence, probe: false))
        if dropping, let index { lose(index) }
        return EchoExpectation(job: job, finalEventSequence: sequence, postedAt: clock.now())
    }

    private func post(_ event: SyntheticKeyEvent, delivery: Delivery) -> UInt32 {
        let sequence = nextEventSequence(delivery)
        try? poster.post(event, userData: marker.userData(sequence: sequence, probe: false))
        return sequence
    }

    private func nextEventSequence(_ delivery: Delivery) -> UInt32 {
        eventSequence = (eventSequence &+ 1) & EventMarker.sequenceMask
        deliveries[eventSequence] = delivery
        return eventSequence
    }

    private func finish(_ sequence: JobSequence, _ expectation: EchoExpectation?) {
        if expectation != nil { onPosted() }
        queue.finished(sequence, expectation: expectation)
    }

    private func record(_ outcome: JobOutcome, for sequence: JobSequence) {
        outcomes[sequence] = outcome
        feedback.record(outcome, for: sequence)
    }

    private func lose(_ index: Int) {
        metrics.lostWhilePostingBroken.increment()
        onLost(index)
    }
}
