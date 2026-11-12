// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared state between the tap (producer) and the worker (consumer). Everything the tap touches here is a
// lock-free push or an atomic load/store (PLT-R304).

public import AppModel
public import RealtimeSupport

/// FIFO of jobs plus the in-flight count of PLT-R311 ("jobs pushed but final event not yet posted").
public final class JobQueue: Sendable {
    /// Capacity above the 256-job liveness ceiling (PLT-R314) so a full ring is never the first symptom.
    public init(capacity: Int = 512, signal: WorkerSignal) { unimplemented() }

    /// Tap: increments `inFlight`, pushes, signals the worker. False when full: the caller passes the event
    /// through and requests a flush.
    public func push(_ job: InjectionJob) -> Bool { unimplemented() }
    /// Tap: one atomic load.
    public var inFlight: Int { unimplemented() }
    /// Tap: next sequence number (single producer, so a plain counter owned by the tap is enough).
    public func nextSequence() -> JobSequence { unimplemented() }

    /// Worker.
    public func pop() -> InjectionJob? { unimplemented() }
    /// Worker: after the final event of a job was posted, or the job was discarded/abandoned.
    public func finished(_ sequence: JobSequence) { unimplemented() }
    public var queuedCount: Int { unimplemented() }
}

public enum JobOutcome: UInt8, Sendable, Hashable {
    case executed, executedWithFallback, abandoned, discardedForGeneration, passedThroughByFallback
}

/// Worker -> tap feedback through atomics.
public final class WorkerFeedback: Sendable {
    public init() { unimplemented() }

    /// Worker increments after a flush or discard; the tap resets the engine when it sees a new value
    /// (PLT-R314 "reset the composition").
    public func requestCompositionReset() { unimplemented() }
    public var compositionResetCount: UInt64 { unimplemented() }

    /// Outcome of recent jobs (64-entry board indexed by sequence) so the tap can decide what to do with the
    /// keyUp of a consumed keyDown whose job already finished (PLT-R313). Nil = unknown or too old.
    public func record(_ outcome: JobOutcome, for sequence: JobSequence) { unimplemented() }
    public func outcome(of sequence: JobSequence) -> JobOutcome? { unimplemented() }

    /// Set by the echo watchdog; read by the tap at callback entry to fail open within the same callback
    /// (PLT-R730).
    public func markPostingBroken() { unimplemented() }
    public var isPostingBroken: Bool { unimplemented() }
}

/// Echo liveness (PLT-R323): the worker records the sequence of each job's last event, the tap records the
/// highest sequence it saw come back.
public final class EchoTracker: Sendable {
    public init(timeout: Duration = .milliseconds(200), missesForBroken: Int = 3) { unimplemented() }
    /// Worker, after posting a job's final event.
    public func expect(_ sequence: UInt32, postedAt: MonotonicInstant) { unimplemented() }
    /// Tap, on a marked event (PLT-R310 step 2).
    public func observed(_ sequence: UInt32, at: MonotonicInstant) { unimplemented() }
    /// Worker or utility: true once three consecutive jobs saw no echo within the timeout.
    public func isBroken(now: MonotonicInstant) -> Bool { unimplemented() }
}

/// Current focus generation, written by the ax thread on every publication, read by the worker to discard
/// stale edits (PLT-R316).
public final class CurrentFocusGeneration: Sendable {
    public init() { unimplemented() }
    public func store(_ generation: FocusGeneration) { unimplemented() }
    public func load() -> FocusGeneration { unimplemented() }
}
