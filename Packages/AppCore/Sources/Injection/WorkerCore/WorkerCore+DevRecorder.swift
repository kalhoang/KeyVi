// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edit jobs for the dev recorder (PLT-R904A, ADR 0007): kind, strategy, outcome, events posted and durations, and
// every strategy fallback with its reason (AX timeouts included), and for a revision what its read-back found
// (PLT-R357, a name only). Debug configuration only; the inject thread is the ring's one producer. Lengths only for
// the edit: the engine step on the tap already holds the text.

#if DEV_RECORDER
internal import AppModel
internal import Diagnostics
internal import RealtimeSupport

extension WorkerCore {
    func recordDevJob(_ job: EditJob, outcome: JobOutcome) {
        guard let dev = services.capture?.dev, dev.isActive else { return }
        let now = services.clock.now()
        let started = context?.startedAt ?? now
        dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: job.sequence.rawValue, generation: job.generation.rawValue, kind: job.kind,
                    strategy: job.plan.strategy, outcome: outcome.captureLabel, deleteCount: job.deleteCount,
                    insertCount: job.insertion.count, eventsPosted: context?.eventsPosted ?? 0,
                    totalMicroseconds: now.nanoseconds(since: job.createdAt) / 1_000,
                    runMicroseconds: now.nanoseconds(since: started) / 1_000, at: now,
                    completion: context?.completion, completionReadMicroseconds: context?.completionReadMicroseconds,
                    completionKeptJobs: context?.completionKept?.jobsSinceRead,
                    completionKeptAgeMicroseconds: context?.completionKept.map {
                        InjectionTiming.nanoseconds($0.readAge) / 1_000
                    },
                    readback: context?.readback)))
    }

    func recordDevFallback(_ job: EditJob, from: InjectionStrategy, to: InjectionStrategy, reason: FallbackReason) {
        guard let dev = services.capture?.dev, dev.isActive else { return }
        dev.pushInject(
            .fallback(sequence: job.sequence.rawValue, from: from, to: to, reason: reason, at: services.clock.now()))
    }
}
#endif
