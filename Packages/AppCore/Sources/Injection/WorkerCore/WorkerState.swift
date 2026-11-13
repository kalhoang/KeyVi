// SPDX-License-Identifier: GPL-3.0-or-later
//
// Worker-local state containers (inject thread only): the backlog of popped but unstarted jobs, the outcome log
// used to resolve paired keyUps (PLT-R313, ADR 0308), and first-edit timing (PLT-R408).

internal import AppModel
internal import RealtimeSupport

/// FIFO of jobs popped from the SPSC ring and not yet started. The worker pulls the ring into it so it can see
/// the oldest waiting event (liveness, PLT-R314) and release held events mid-job (PLT-R408, PLT-R461 step 4).
struct JobBacklog {
    private var storage: [InjectionJob?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(2, capacity))
    }

    var isEmpty: Bool { count == 0 }
    var first: InjectionJob? { count == 0 ? nil : storage[head] }

    mutating func append(_ job: InjectionJob) {
        if count == storage.count { grow() }
        storage[(head + count) % storage.count] = job
        count += 1
    }

    mutating func popFirst() -> InjectionJob? {
        guard count > 0 else { return nil }
        let job = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return job
    }

    private mutating func grow() {
        var larger: [InjectionJob?] = Array(repeating: nil, count: storage.count * 2)
        for index in 0..<count { larger[index] = storage[(head + index) % storage.count] }
        storage = larger
        head = 0
    }
}

/// Outcomes of recent edit jobs. Larger than `WorkerFeedback`'s 64-entry board because a pairedKeyUp can sit
/// behind many replays of an autorepeating key; twice the ring capacity always covers it.
struct OutcomeLog {
    private var slots: [UInt64]

    init(capacity: Int) { slots = Array(repeating: 0, count: max(64, capacity)) }

    mutating func record(_ outcome: JobOutcome, for sequence: JobSequence) {
        slots[Int(sequence.rawValue % UInt64(slots.count))] = (sequence.rawValue << 8) | UInt64(outcome.rawValue + 1)
    }

    func outcome(of sequence: JobSequence) -> JobOutcome? {
        let value = slots[Int(sequence.rawValue % UInt64(slots.count))]
        guard value != 0, value >> 8 == sequence.rawValue & (UInt64.max >> 8) else { return nil }
        return JobOutcome(rawValue: UInt8(truncatingIfNeeded: value & 0xFF) &- 1)
    }
}

extension JobOutcome {
    /// The trigger's effect was delivered by the job, so its keyUp is consumed (PLT-R313).
    var deliveredEdit: Bool { self == .executed || self == .executedWithFallback }

    var captureLabel: StaticString {
        switch self {
        case .executed: "executed"
        case .executedWithFallback: "executedWithFallback"
        case .abandoned: "abandoned"
        case .discardedForGeneration: "discardedForGeneration"
        case .passedThroughByFallback: "passedThroughByFallback"
        }
    }
}

/// PLT-R408 `firstEditDelayUs` applies before the first edit of a word that began near a focus change or click.
/// The pipeline flags every job of such a word; the worker applies the delay only to the first of them: the
/// previous executed edit was not flagged, was in another focus generation, or a `BoundaryJob` came between.
struct FirstEditTiming {
    private var previousFlagged = false
    private var previousGeneration: FocusGeneration?
    private var boundarySeen = true

    mutating func applies(to job: EditJob) -> Bool {
        defer {
            previousFlagged = job.wordStartedNearFocusChange
            previousGeneration = job.generation
            boundarySeen = false
        }
        guard job.wordStartedNearFocusChange else { return false }
        return boundarySeen || !previousFlagged || previousGeneration != job.generation
    }

    mutating func boundary() { boundarySeen = true }
}

/// Instants the worker has to act on without new jobs: clipboard restore (PLT-R461) and deferred readback
/// (PLT-R410).
struct IdleState: Sendable {
    var isIdle: Bool
    var deadline: MonotonicInstant?
}

extension InjectionJob {
    var sequence: JobSequence {
        switch self {
        case .edit(let job): job.sequence
        case .replay(let sequence, _), .pairedKeyUp(let sequence, _, _): sequence
        case .boundary(let job): job.sequence
        }
    }

    /// When the key behind this job reached the tap (PLT-R314: age of the oldest waiting event).
    var waitingSince: MonotonicInstant? {
        switch self {
        case .edit(let job): job.trigger?.receivedAt ?? job.createdAt
        case .replay(_, let record), .pairedKeyUp(_, let record, _): record.receivedAt
        case .boundary: nil
        }
    }

    var isHeldEvent: Bool {
        switch self {
        case .replay, .pairedKeyUp: true
        case .edit, .boundary: false
        }
    }
}
