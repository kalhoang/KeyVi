// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R423 caret continuity (amendment of 16/11/2026, second retest of beta 2): what the worker remembers of the last
// `forwardDelete` read that found the caret at the end of the text, and when a later read that timed out may keep
// that answer.

internal import AppModel
internal import RealtimeSupport

/// In one Spotlight session on macOS 27.2 the completion read took 3.2, 14.6 and 27.2 ms and then more than its 50 ms
/// bound: every edit changes the query, and the next read waits behind the search on Spotlight's main thread. A fixed
/// bound only moves the failure a few keys later. A caret at the end of the text with nothing selected stays at the end
/// through everything the tap counts as typing (a character typed or a Backspace, `CaretContinuity.keepsCaret` in
/// InputHost) and through this worker's own edits (Backspaces, Forward Deletes at the end, which delete nothing, and
/// insertions). The tap breaks the continuity (`JobQueue.breakCaretContinuity`) on everything else that can move the
/// caret, so while its epoch has not moved since the answer was read, in the same focus session and field, that answer
/// still holds.
///
/// Inject thread only. A fresh answer always wins: the memory is consulted only when the read timed out. A read that
/// fails at once (`.unavailable`, `.failed`) means the field is gone or refused, not busy, so it forgets instead.
struct CaretAtEndMemory {
    /// How an answer was kept, for the dev recorder's job line (PLT-R904A).
    struct Kept: Sendable, Hashable {
        /// Completion decisions since the read that answered, this one included (1: the previous edit read it).
        var jobsSinceRead: Int
        /// How long ago that read answered.
        var readAge: TimeSpan
    }

    private struct Answer {
        var generation: FocusGeneration
        var pid: Int32
        var field: UInt64
        var epoch: UInt64
        var answeredAt: MonotonicInstant
        var jobsSinceRead: Int
    }

    private var answer: Answer?

    /// A read for `job` found the caret at the end of the text. Remembered only when the job was built in the epoch
    /// that was current right before the read: after a click between the key and the read, the app may not have
    /// applied the click when it answered (residual risk (a) of PLT-R423), so that answer serves its own job only.
    mutating func remember(_ job: EditJob, epochBeforeRead: UInt64, answeredAt: MonotonicInstant) {
        guard let field = job.field, job.caretEpoch == epochBeforeRead else {
            answer = nil
            return
        }
        answer = Answer(
            generation: job.generation, pid: field.pid, field: field.token, epoch: epochBeforeRead,
            answeredAt: answeredAt, jobsSinceRead: 0)
    }

    /// The read for `job` timed out: the remembered answer if it still holds, that is, the same focus session and
    /// field, and neither the job's epoch nor the live one (`liveEpoch`, loaded after the read timed out, so a click
    /// during the read counts) moved since the answer. An answer that no longer holds is dropped for good: epochs and
    /// generations only grow.
    mutating func keep(for job: EditJob, liveEpoch: UInt64, now: MonotonicInstant) -> Kept? {
        guard var held = answer, let field = job.field, held.generation == job.generation, held.pid == field.pid,
            held.field == field.token, held.epoch == job.caretEpoch, held.epoch == liveEpoch
        else {
            answer = nil
            return nil
        }
        held.jobsSinceRead += 1
        answer = held
        return Kept(jobsSinceRead: held.jobsSinceRead, readAge: now.duration(since: held.answeredAt))
    }

    /// A read found a selection or the caret before the end, or something left the field unlike what the engine
    /// believes (an edit not applied as computed, a flush, a boundary, broken posting).
    mutating func forget() { answer = nil }
}
