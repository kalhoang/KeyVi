// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The serial injection worker on the dedicated `inject` thread (PLT-R203, PLT-R311-R317, section 4).

internal import AppModel
public import Diagnostics
public import RealtimeSupport
internal import Synchronization

public struct WorkerConfiguration: Sendable, Hashable {
    /// Oldest held event may wait this long before a flush (PLT-R314, VERIFY tuning).
    public var livenessCeiling: Duration = .milliseconds(150)
    /// Ceiling while a macro job runs (PLT-R480).
    public var macroLivenessCeiling: Duration = .seconds(1)
    /// Queue length that forces a flush (PLT-R314).
    public var maxQueuedJobs: Int = 256
    /// Jobs longer than this are split (if `allowSplit`) or use the fallback (PLT-R408).
    public var maxJobDuration: Duration = .milliseconds(150)
    /// Long text: chunked Unicode up to 2,000 graphemes, paste above if opted in; hard cap 4,000 (PLT-R480).
    public var pasteThresholdGraphemes: Int = 2_000
    public var maximumExpansionGraphemes: Int = 4_000
    public init() {}
}

public struct InjectionServices: Sendable {
    public var poster: any EventPoster
    public var fieldAccess: any FocusedFieldAccess
    public var pasteboard: any PasteboardAccess
    public var clock: any MonotonicClock
    public var metrics: PlatformMetrics
    public var health: HealthEventLog
    public var logger: any DiagnosticsLogging
    public var capture: CaptureController?

    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, pasteboard: any PasteboardAccess,
        clock: any MonotonicClock, metrics: PlatformMetrics, health: HealthEventLog,
        logger: any DiagnosticsLogging, capture: CaptureController?
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
        self.clock = clock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.capture = capture
    }
}

/// Reasons the host asks the worker to flush outside the normal liveness check.
public enum FlushReason: UInt8, Sendable, Hashable {
    case tapDisabled  // PLT-R330 step 3
    case failOpen  // PLT-R730
    case queueFull
}

/// The serial worker. It owns the marker event sequence: every posted event (edit, replay, probe) gets the
/// next 23-bit sequence, and after a job's final event it calls `JobQueue.finished(_:expectation:)` with that
/// sequence so the tap can settle the job on its echo (ADR 0311). Jobs that post nothing finish with `nil`.
/// While `WorkerFeedback.isPostingBroken` is set it posts nothing: held events and triggers that cannot be
/// delivered are counted in `PlatformMetrics.lostWhilePostingBroken` and one `postingBroken` health event
/// with `.count(n)` (ADR 0308, ADR 0311); conservation (PLT-R312) is guaranteed only while posting works.
public final class InjectionWorker: Sendable {
    private let core: Mutex<WorkerCore>
    private let control: WorkerControl

    public init(
        queue: JobQueue, signal: WorkerSignal, feedback: WorkerFeedback, marker: EventMarker,
        focusGeneration: CurrentFocusGeneration, services: InjectionServices,
        configuration: WorkerConfiguration = WorkerConfiguration()
    ) {
        let control = WorkerControl(signal: signal)
        self.control = control
        core = Mutex(
            WorkerCore(
                queue: queue, feedback: feedback, marker: marker, focusGeneration: focusGeneration,
                services: services, configuration: configuration, control: control))
    }

    /// Spawns the `inject` thread (QoS user-interactive). The loop drains jobs, executes them FIFO, sleeps
    /// only on its own signal with absolute deadlines (pacing, liveness), and never waits on the main or tap
    /// thread (PLT-R315).
    public func start() { control.start { [self] in runThreadLoop() } }
    public func stop() { control.stop() }

    /// Asynchronous request (atomic flag + signal): abandon unstarted edit jobs (replaying their triggers),
    /// replay every held event in order, request a composition reset, record a `flush` health event.
    public func requestFlush(_ reason: FlushReason) { control.requestFlush(reason) }

    /// Deterministic mode for tests and the pipeline harness: runs the loop body on the caller's thread until
    /// the queue is empty and no deadline is pending, using the injected (fake) clock.
    public func runUntilIdle() { core.withLock { $0.runUntilIdle() } }

    /// Body of the `inject` thread: process, then wait on the worker signal until the next deadline.
    private func runThreadLoop() {
        while !control.isStopRequested {
            let idle = core.withLock { $0.runAvailable() }
            guard !control.isStopRequested else { return }
            if idle.isIdle { _ = control.signal.wait(until: idle.deadline) }
        }
    }
}
