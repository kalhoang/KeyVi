// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The worker's loop body (PLT-R311-R316, ADR 0308, ADR 0311). Confined to the `inject` thread, or to the caller
// of `runUntilIdle` in step mode; `InjectionWorker` serialises access through an uncontended lock.

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import RealtimeSupport

/// Bookkeeping of the job being executed: did it post anything (then it finishes with an expectation).
struct JobContext {
    var sequence: JobSequence
    var posted = false
}

struct PostedEvent {
    var sequence: UInt32
    var at: MonotonicInstant
}

final class WorkerCore {
    let queue: JobQueue
    let feedback: WorkerFeedback
    let marker: EventMarker
    let focusGeneration: CurrentFocusGeneration
    let services: InjectionServices
    let configuration: WorkerConfiguration
    let control: WorkerControl
    let preserver: PasteboardPreserver
    let axAccess: InstrumentedFieldAccess
    let executors: [InjectionStrategy: any StrategyExecutor]

    var backlog: JobBacklog
    var outcomes: OutcomeLog
    var firstEdit = FirstEditTiming()
    var notes = SessionNotes()
    /// Last marker sequence used; the first event gets 0 (23-bit wrapping, PLT-R321).
    var eventSequence: UInt32 = EventMarker.sequenceMask
    var lastPosted: PostedEvent?
    var context: JobContext?
    /// Sequence of the edit being executed, for pairedKeyUps released mid-job.
    var runningEdit: JobSequence?
    /// When the last macro job finished: keys received before it waited behind the macro (PLT-R480).
    var lastMacroFinishedAt: MonotonicInstant?
    /// Undeliverable events since the last `postingBroken` health event (ADR 0311).
    var unreportedLosses = 0
    var restoreDelay: Duration?
    var pendingVerification: PendingVerification?

    init(
        queue: JobQueue, feedback: WorkerFeedback, marker: EventMarker, focusGeneration: CurrentFocusGeneration,
        services: InjectionServices, configuration: WorkerConfiguration, control: WorkerControl
    ) {
        self.queue = queue
        self.feedback = feedback
        self.marker = marker
        self.focusGeneration = focusGeneration
        self.services = services
        self.configuration = configuration
        self.control = control
        preserver = PasteboardPreserver(pasteboard: services.pasteboard)
        axAccess = InstrumentedFieldAccess(base: services.fieldAccess)
        let limits = StrategyLimits(configuration)
        executors = Dictionary(
            uniqueKeysWithValues: InjectionStrategy.allCases.map {
                ($0, BuiltInExecutors.executor(for: $0, limits: limits))
            })
        backlog = JobBacklog(capacity: queue.capacity)
        outcomes = OutcomeLog(capacity: queue.capacity * 2)
    }

    // MARK: Loop

    /// Executes every available job FIFO, then services due deadlines. Returns whether the worker is idle and
    /// the next instant it must wake up without a signal.
    func runAvailable() -> IdleState {
        while true {
            pullFromRing()
            if let reason = control.takeFlushRequest() {
                flush(reason: reason)
                continue
            }
            if livenessExceeded() {
                flush(reason: nil)
                continue
            }
            guard let job = backlog.popFirst() else { break }
            process(job)
            serviceDeadlines(idle: false)
        }
        serviceDeadlines(idle: true)
        let idle = backlog.isEmpty && queue.queuedCount == 0
        if idle { reportLosses() }
        return IdleState(isIdle: idle, deadline: nextDeadline())
    }

    func runUntilIdle() {
        while true {
            let state = runAvailable()
            guard state.isIdle else { continue }
            guard let deadline = state.deadline else { return }
            services.clock.sleep(until: deadline)
        }
    }

    func pullFromRing() {
        while let job = queue.pop() { backlog.append(job) }
    }

    /// PLT-R314: more than `maxQueuedJobs` waiting, or the oldest waiting key older than the ceiling (1 s for keys
    /// that waited behind a macro job, PLT-R480).
    func livenessExceeded() -> Bool {
        if backlog.count + queue.queuedCount > configuration.maxQueuedJobs { return true }
        guard let since = backlog.first?.waitingSince else { return false }
        let waitedBehindMacro = lastMacroFinishedAt.map { since < $0 } ?? false
        let ceiling = waitedBehindMacro ? configuration.macroLivenessCeiling : configuration.livenessCeiling
        return services.clock.now().nanoseconds(since: since) > InjectionTiming.nanoseconds(ceiling)
    }

    /// PLT-R314 / `requestFlush`: abandon unstarted edits (replaying their triggers, ADR 0308), replay held events
    /// in order, request a composition reset, record a `flush` health event.
    func flush(reason: FlushReason?) {
        pullFromRing()
        var abandoned = 0
        while let job = backlog.popFirst() {
            if case .edit(let edit) = job {
                begin(edit.sequence)
                replayTrigger(of: edit)
                finishEdit(edit, outcome: .abandoned)
                abandoned += 1
            } else {
                process(job)
            }
        }
        feedback.requestCompositionReset()
        services.metrics.flushes.increment()
        recordHealth(.flush, detail: .count(abandoned))
        if reason == .queueFull {
            services.logger.log(.note("flush after a full queue", category: .injection), level: .notice)
        }
    }

    // MARK: Jobs

    func process(_ job: InjectionJob) {
        switch job {
        case .edit(let edit): processEdit(edit)
        case .replay(let sequence, let record):
            begin(sequence)
            deliverHeld(record)
            finish()
        case .pairedKeyUp(let sequence, let record, let forJob):
            begin(sequence)
            // PLT-R313 / ADR 0308: dropped if the job delivered its edit, replayed otherwise (unknown: replay, a
            // stray keyUp is harmless while a missing one leaves a key stuck).
            let outcome: JobOutcome? =
                forJob == runningEdit ? .executed : outcomes.outcome(of: forJob) ?? feedback.outcome(of: forJob)
            if outcome?.deliveredEdit != true { deliverHeld(record) }
            finish()
        case .boundary(let boundary):
            begin(boundary.sequence)
            firstEdit.boundary()
            finish()
        }
    }

    func begin(_ sequence: JobSequence) { context = JobContext(sequence: sequence) }

    /// Exactly one `finished` per job: with an expectation iff the job posted (ADR 0311). The expectation names the
    /// latest posted event, which is the job's own last event or a held event released after it; echoes arrive
    /// in posting order, so expectations stay monotonic.
    func finish() {
        guard let finished = context else { return }
        context = nil
        var expectation: EchoExpectation?
        if finished.posted, let lastPosted {
            expectation = EchoExpectation(
                job: finished.sequence, finalEventSequence: lastPosted.sequence, postedAt: lastPosted.at)
        }
        queue.finished(finished.sequence, expectation: expectation)
    }

    // MARK: Posting

    func nextEventSequence() -> UInt32 {
        eventSequence = (eventSequence &+ 1) & EventMarker.sequenceMask
        return eventSequence
    }

    func notePosted(_ sequence: UInt32) {
        lastPosted = PostedEvent(sequence: sequence, at: services.clock.now())
        context?.posted = true
    }

    /// Replays a held or trigger event with the marker (PLT-R324). Always the echo kind: a probe-kind marker would
    /// make the tap process the replay as a new physical probe and hold it again; probe metrics are routed by
    /// `isProbe` instead (PLT-R810). While posting is broken nothing is posted and the event is counted as lost.
    @discardableResult
    func replay(_ record: KeyEventRecord) -> Bool {
        guard !feedback.isPostingBroken else {
            countLoss()
            return false
        }
        let sequence = nextEventSequence()
        do {
            try services.poster.replay(record, userData: marker.userData(sequence: sequence, probe: false))
        } catch {
            services.logger.log(.note("replay event creation failed", category: .injection), level: .error)
            return false
        }
        notePosted(sequence)
        return true
    }

    /// A held event (ReplayJob or abandoned pairedKeyUp) with the T5 held-wait metric.
    func deliverHeld(_ record: KeyEventRecord) {
        guard replay(record), !record.isProbe else { return }
        services.metrics.heldWait.record(nanoseconds: services.clock.now().nanoseconds(since: record.receivedAt))
    }

    func replayTrigger(of job: EditJob) {
        if let trigger = job.trigger { replay(trigger) }
    }

    func countLoss() {
        unreportedLosses += 1
        services.metrics.lostWhilePostingBroken.increment()
    }

    /// One `postingBroken` health event with the count once the backlog drained (ADR 0308 amendment).
    func reportLosses() {
        guard unreportedLosses > 0 else { return }
        recordHealth(.postingBroken, detail: .count(unreportedLosses))
        unreportedLosses = 0
    }

    func recordHealth(_ kind: HealthEvent.Kind, detail: HealthEvent.Detail? = nil) {
        services.health.record(HealthEvent(kind: kind, at: Date(), detail: detail))
    }
}
