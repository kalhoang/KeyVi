// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared state between the tap (producer) and the worker (consumer). Everything the tap touches here is a
// lock-free push or pop or an atomic load/store (PLT-R304). Implemented in the skeleton because it is the seam
// between the pipeline (W1-F1) and the worker (W1-D) (docs/decisions/0313-testability-seams.md); W1-D owns it.
//
// "In flight" follows docs/decisions/0311-in-flight-until-echo.md: a job stays in flight until the tap sees
// the echo of the job's final synthetic event, or the echo timeout passes, or the worker reports that the job
// posted nothing. Reading PLT-R311 by its rationale: a physical key that reached the WindowServer before the
// job's events were posted reaches the tap before their echo, so it is held instead of overtaking them.

public import AppModel
public import Diagnostics
public import RealtimeSupport
internal import Synchronization

/// When a job stops counting as in flight (ADR 0311).
public enum InFlightPolicy: UInt8, Sendable, Hashable {
    /// Until the tap sees the echo of the job's final event, or `EchoTracker.timeout` passes (default).
    case untilEcho
    /// Until the worker has posted the job's final event. Fallback if PLT-R301 VERIFY (a) shows that echoes are
    /// not delivered to the app's own tap (PLT-R323 "fall back to permission polling only").
    case untilPosted
}

/// The worker's note that a job's final event was posted (PLT-R323).
public struct EchoExpectation: Sendable, Hashable, BitwiseCopyable {
    public var job: JobSequence
    /// Marker sequence (23 bits, `EventMarker`) of the job's last posted event.
    public var finalEventSequence: UInt32
    public var postedAt: MonotonicInstant

    public init(job: JobSequence, finalEventSequence: UInt32, postedAt: MonotonicInstant) {
        self.job = job
        self.finalEventSequence = finalEventSequence
        self.postedAt = postedAt
    }
}

/// FIFO of jobs plus the in-flight count of PLT-R311.
public final class JobQueue: Sendable {
    public let policy: InFlightPolicy
    public let capacity: Int
    private let jobs: SPSCRing<InjectionJob>
    /// Worker -> tap: expectations of jobs that posted events (drained by `EchoTracker` on the tap).
    let expectations: SPSCRing<EchoExpectation>
    private let signal: WorkerSignal
    private let pushed = Atomic<UInt64>(0)  // written by the tap only
    private let settledByTap = Atomic<UInt64>(0)  // written by the tap only (echo seen or timed out)
    private let settledByWorker = Atomic<UInt64>(0)  // written by the worker only (nothing posted, or policy)
    private let sequence = Atomic<UInt64>(0)  // written by the tap only

    /// Capacity above the 256-job liveness ceiling (PLT-R314) so a full ring is never the first symptom.
    /// Rounded up to a power of two.
    public init(capacity: Int = 512, signal: WorkerSignal, policy: InFlightPolicy = .untilEcho) {
        var size = 1
        while size < max(2, capacity) { size <<= 1 }
        self.capacity = size
        self.policy = policy
        self.signal = signal
        jobs = SPSCRing(capacity: size)
        expectations = SPSCRing(capacity: size)
    }

    /// Tap: pushes, counts the job as in flight, signals the worker. False when full: the caller passes the
    /// event through and requests a flush.
    @inline(__always)
    public func push(_ job: InjectionJob) -> Bool {
        guard jobs.push(job) else { return false }
        pushed.wrappingAdd(1, ordering: .sequentiallyConsistent)
        signal.signal()
        return true
    }

    /// Tap: jobs pushed and not yet settled (two atomic loads and one subtraction).
    @inline(__always)
    public var inFlight: Int {
        let total = pushed.load(ordering: .sequentiallyConsistent)
        let settled =
            settledByTap.load(ordering: .sequentiallyConsistent)
            &+ settledByWorker.load(ordering: .sequentiallyConsistent)
        return Int(truncatingIfNeeded: total &- settled)
    }

    /// Tap: next job sequence (single producer).
    @inline(__always)
    public func nextSequence() -> JobSequence {
        JobSequence(rawValue: sequence.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    /// Worker.
    public func pop() -> InjectionJob? { jobs.pop() }

    /// Worker: the job ended. `expectation` is nil when the job posted nothing (a `BoundaryJob`, a dropped
    /// `pairedKeyUp`, an edit that turned out empty): it settles immediately. Otherwise, with `.untilEcho`, the
    /// job stays in flight until the tap settles it (`EchoTracker`); with `.untilPosted` it settles now.
    public func finished(_ sequence: JobSequence, expectation: EchoExpectation?) {
        guard let expectation, policy == .untilEcho else {
            settledByWorker.wrappingAdd(1, ordering: .sequentiallyConsistent)
            return
        }
        if !expectations.push(expectation) {
            // Cannot happen while at most `capacity` jobs are in flight; settle rather than block the keyboard.
            settledByWorker.wrappingAdd(1, ordering: .sequentiallyConsistent)
        }
    }

    /// Jobs pushed and not yet popped (approximate from other threads).
    public var queuedCount: Int { jobs.count }

    /// Tap (EchoTracker): `count` jobs settled by echo or timeout.
    @inline(__always)
    func settleByTap(_ count: Int) {
        settledByTap.wrappingAdd(UInt64(count), ordering: .sequentiallyConsistent)
    }
}

public enum JobOutcome: UInt8, Sendable, Hashable {
    case executed, executedWithFallback, abandoned, discardedForGeneration, passedThroughByFallback
}

/// Worker -> tap feedback through atomics.
public final class WorkerFeedback: Sendable {
    public static let boardSize = 64
    private let resetCount = Atomic<UInt64>(0)
    private let postingBroken = Atomic<Bool>(false)
    /// Slot i holds `(sequence << 8) | (outcome + 1)` for the most recent job with `sequence % 64 == i`.
    private let board = AtomicUInt64Array(count: WorkerFeedback.boardSize)

    public init() {}

    /// Worker increments after a flush or discard; the tap resets the engine when it sees a new value
    /// (PLT-R314 "reset the composition").
    public func requestCompositionReset() { resetCount.wrappingAdd(1, ordering: .sequentiallyConsistent) }
    public var compositionResetCount: UInt64 { resetCount.load(ordering: .sequentiallyConsistent) }

    /// Outcome of recent jobs (64-entry board indexed by sequence) so the tap can decide what to do with the
    /// keyUp of a consumed keyDown whose job already finished (PLT-R313). Nil = unknown or too old.
    public func record(_ outcome: JobOutcome, for sequence: JobSequence) {
        let slot = Int(sequence.rawValue % UInt64(Self.boardSize))
        board.store((sequence.rawValue << 8) | UInt64(outcome.rawValue + 1), at: slot)
    }

    public func outcome(of sequence: JobSequence) -> JobOutcome? {
        let value = board.load(Int(sequence.rawValue % UInt64(Self.boardSize)))
        guard value != 0, value >> 8 == sequence.rawValue & (UInt64.max >> 8) else { return nil }
        return JobOutcome(rawValue: UInt8(truncatingIfNeeded: value & 0xFF) &- 1)
    }

    /// Set by the tap after three consecutive echo misses (ADR 0311) or by the utility queue when
    /// `CGPreflightPostEventAccess()` turns false after a miss; read by the tap at callback entry to fail open
    /// within the same callback (PLT-R730). Cleared by the lifecycle owner when posting works again.
    public func markPostingBroken() { postingBroken.store(true, ordering: .sequentiallyConsistent) }
    public func clearPostingBroken() { postingBroken.store(false, ordering: .sequentiallyConsistent) }
    public var isPostingBroken: Bool { postingBroken.load(ordering: .sequentiallyConsistent) }
}

/// Result of the tap's per-callback echo bookkeeping.
public enum EchoHealth: Sendable, Hashable {
    case healthy
    /// `missesForBroken` consecutive jobs saw no echo within the timeout (PLT-R323): fail open (PLT-R730).
    case postingBroken
}

/// Echo liveness and in-flight settlement (PLT-R323, ADR 0311). TAP THREAD ONLY except `consecutiveMisses`.
/// The worker publishes `EchoExpectation`s through `JobQueue.finished`; the tap drains them at callback entry,
/// settles jobs whose final event echoed or whose echo timed out, and counts consecutive misses. The pending
/// list is allocated once (capacity = queue capacity), so the tap path never allocates.
public final class EchoTracker: @unchecked Sendable {
    public let timeout: Duration
    public let missesForBroken: Int
    private let queue: JobQueue
    /// PLT-R801 echo round trip (`PlatformMetrics.echoRoundTrip`); atomic increments only.
    private let roundTrip: Log2Histogram?
    private let pending: UnsafeMutablePointer<EchoExpectation>
    private let pendingCapacity: Int
    // Tap-thread state.
    private var head = 0
    private var count = 0
    private var highestEcho: UInt32 = 0
    /// When the echo that raised `highestEcho` arrived: the round trip of a job ends no later than that.
    private var highestEchoAt = MonotonicInstant.zero
    private var hasSeenEcho = false
    private var misses = 0
    private let missesMirror = Atomic<Int>(0)
    /// One past the latest instant (monotonic nanoseconds) up to which unechoed expectations were lost while the
    /// tap was disabled (0: none). Written by the tap or the lifecycle owner, read by the tap at settlement.
    private let forgivenBound = Atomic<UInt64>(0)

    public init(
        queue: JobQueue, timeout: Duration = .milliseconds(200), missesForBroken: Int = 3,
        roundTrip: Log2Histogram? = nil
    ) {
        self.queue = queue
        self.timeout = timeout
        self.missesForBroken = missesForBroken
        self.roundTrip = roundTrip
        pendingCapacity = queue.capacity
        pending = .allocate(capacity: queue.capacity)
    }

    deinit { pending.deallocate() }

    /// Tap, at callback entry (after PLT-R310 step 1): pulls new expectations, settles those whose echo was
    /// already seen and those older than `timeout` (each timeout is a miss and settles its job).
    public func settle(now: MonotonicInstant) -> EchoHealth {
        while count < pendingCapacity, let expectation = queue.expectations.pop() {
            pending[(head + count) % pendingCapacity] = expectation
            count += 1
        }
        var settled = 0
        let timeoutNanoseconds =
            UInt64(timeout.components.seconds) * 1_000_000_000
            + UInt64(timeout.components.attoseconds / 1_000_000_000)
        let forgiven = forgivenBound.load(ordering: .sequentiallyConsistent)
        while count > 0 {
            let front = pending[head]
            if hasSeenEcho && Self.isAtOrBefore(front.finalEventSequence, highestEcho) {
                misses = 0
                roundTrip?.record(nanoseconds: highestEchoAt.nanoseconds(since: front.postedAt))
            } else if front.postedAt.nanoseconds < forgiven {
                // PLT-R330, PLT-R306: posted before the tap was re-enabled, so its echo bypassed the disabled
                // tap and will never come. Settled at once without counting a miss: the posting path is fine.
            } else if now.nanoseconds(since: front.postedAt) > timeoutNanoseconds {
                misses += 1
            } else {
                break
            }
            head = (head + 1) % pendingCapacity
            count -= 1
            settled += 1
        }
        if settled > 0 { queue.settleByTap(settled) }
        missesMirror.store(misses, ordering: .relaxed)
        return misses >= missesForBroken ? .postingBroken : .healthy
    }

    /// Tap, on a marked echo (PLT-R310 step 2): records the watermark and settles every pending expectation at
    /// or before it. Echoes arrive in posting order, and one that arrives before its expectation was drained is
    /// matched by the watermark when the expectation shows up.
    public func observed(_ sequence: UInt32, at now: MonotonicInstant) {
        if !hasSeenEcho || Self.isAtOrBefore(highestEcho, sequence) {
            highestEcho = sequence
            highestEchoAt = now
        }
        hasSeenEcho = true
        _ = settle(now: now)
    }

    /// Any thread: the tap was disabled (a tap-disabled event, a watchdog trip) and is being re-enabled.
    /// Synthetic events posted while it was disabled, or queued behind a stuck callback and released by the
    /// disable, never pass through it, so their echoes never arrive. Every expectation posted at or before
    /// `instant` that has not echoed is settled at the next settlement without counting a miss (PLT-R330,
    /// PLT-R306, PLT-R323: only a run of misses on an enabled tap means posting is broken). One atomic max; the
    /// bound never moves backwards.
    public func forgiveLostEchoes(postedAtOrBefore instant: MonotonicInstant) {
        let bound = instant.nanoseconds == .max ? UInt64.max : instant.nanoseconds + 1
        forgivenBound.max(bound, ordering: .sequentiallyConsistent)
    }

    /// Any thread (diagnostics).
    public var consecutiveMisses: Int { missesMirror.load(ordering: .relaxed) }

    /// Wrapping comparison over the 23-bit marker sequence space.
    @inline(__always)
    static func isAtOrBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        ((rhs &- lhs) & EventMarker.sequenceMask) < (EventMarker.sequenceMask >> 1)
    }
}

/// Current focus generation, written by the ax thread on every publication, read by the worker to discard
/// stale edits (PLT-R316).
public final class CurrentFocusGeneration: Sendable {
    private let value = Atomic<UInt64>(0)
    public init() {}
    public func store(_ generation: FocusGeneration) {
        value.store(generation.rawValue, ordering: .sequentiallyConsistent)
    }
    public func load() -> FocusGeneration { FocusGeneration(rawValue: value.load(ordering: .sequentiallyConsistent)) }
}
