// SPDX-License-Identifier: LicenseRef-App-Pending
//
// A `KeyPipeline` wired to real seams (JobQueue, EchoTracker, WorkerFeedback, metrics, rings) and published
// snapshots, driven event by event from the test thread, which plays the tap thread. Step tests pop the jobs
// themselves; the property harness adds a consumer and a window-server model on top.

internal import AppModel
public import Diagnostics
public import Injection
public import InputHost
internal import RealtimeSupport

public final class PipelineFixture {
    public typealias Pipeline = KeyPipeline<ScriptedEngineFactory, ManualClock>

    public let clock: ManualClock
    public let snapshots: TapSnapshots
    public let queue: JobQueue
    public let feedback = WorkerFeedback()
    public let echo: EchoTracker
    public let marker = EventMarker(tag: 0xA5_A5A5_A5A5)
    public let outbox: TapOutbox
    public let metrics = PlatformMetrics()
    public let tapLog = TapLogRing()
    public let watchdog = CallbackWatchdog(activitySignal: nil)
    public let focusGeneration = CurrentFocusGeneration()
    public let log: EngineEventLog
    /// The shared objects, for tests that build a second pipeline with another factory or clock.
    public let context: PipelineContext
    public let pipeline: Pipeline
    private var mainReceived: [MainNotice] = []
    private var axReceived: [AXNotice] = []

    public init(
        settings: TapSettingsSnapshot = PipelineFixtures.settings(), focus: FocusSnapshot = PipelineFixtures.focus(),
        inputSource: InputSourceSnapshot = PipelineFixtures.inputSource(),
        secureInput: SecureInputSnapshot = .initial, lifecycle: LifecycleSnapshot = PipelineFixtures.lifecycle(),
        policy: InFlightPolicy = .untilEcho, queueCapacity: Int = 512, clock: ManualClock = ManualClock(),
        log: EngineEventLog = EngineEventLog()
    ) {
        self.clock = clock
        self.log = log
        let epoch = ReaderEpoch()
        snapshots = TapSnapshots(
            epoch: epoch, settings: SnapshotCell(settings, epoch: epoch), focus: SnapshotCell(focus, epoch: epoch),
            inputSource: SnapshotCell(inputSource, epoch: epoch), secureInput: SnapshotCell(secureInput, epoch: epoch),
            lifecycle: SnapshotCell(lifecycle, epoch: epoch))
        queue = JobQueue(capacity: queueCapacity, signal: WorkerSignal(), policy: policy)
        echo = EchoTracker(queue: queue, roundTrip: metrics.echoRoundTrip)
        outbox = TapOutbox(
            toMain: SPSCRing(capacity: 256), toAX: SPSCRing(capacity: 256), mainSignal: PipelineFixtures.wakeSignal,
            axSignal: PipelineFixtures.wakeSignal)
        focusGeneration.store(focus.generation)
        context = PipelineContext(
            snapshots: snapshots, queue: queue, feedback: feedback, echo: echo, marker: marker, outbox: outbox,
            metrics: metrics, tapLog: tapLog, capture: nil, watchdog: watchdog)
        pipeline = Pipeline(context: context, factory: ScriptedEngineFactory(log: log), clock: clock)
    }

    // MARK: Events

    /// Sends one event at the current virtual time.
    @discardableResult
    public func send(_ event: RawKeyEvent) -> TapVerdict {
        var event = event
        event.receivedAt = clock.now()
        return pipeline.handle(event)
    }

    @discardableResult
    public func keyDown(_ keyCode: UInt16, flags: UInt64 = 0, autorepeat: Bool = false) -> TapVerdict {
        send(PipelineFixtures.keyEvent(.keyDown, keyCode, flags: flags, autorepeat: autorepeat))
    }

    @discardableResult
    public func keyUp(_ keyCode: UInt16, flags: UInt64 = 0) -> TapVerdict {
        send(PipelineFixtures.keyEvent(.keyUp, keyCode, flags: flags))
    }

    /// keyDown then keyUp; returns the keyDown's verdict.
    @discardableResult
    public func press(_ keyCode: UInt16, flags: UInt64 = 0) -> TapVerdict {
        let verdict = keyDown(keyCode, flags: flags)
        keyUp(keyCode, flags: flags)
        return verdict
    }

    @discardableResult
    public func flags(_ keyCode: UInt16, _ flags: UInt64) -> TapVerdict {
        send(PipelineFixtures.keyEvent(.flagsChanged, keyCode, flags: flags))
    }

    public var lastOutcome: EventOutcome? { pipeline.lastOutcome }

    // MARK: Snapshots (the producers' side)

    public func publish(settings: TapSettingsSnapshot) { snapshots.settings.publish(settings) }
    public func publish(focus: FocusSnapshot) {
        snapshots.focus.publish(focus)
        focusGeneration.store(focus.generation)
    }
    public func publish(inputSource: InputSourceSnapshot) { snapshots.inputSource.publish(inputSource) }
    public func publish(secureInput: SecureInputSnapshot) { snapshots.secureInput.publish(secureInput) }
    public func publish(lifecycle: LifecycleSnapshot) { snapshots.lifecycle.publish(lifecycle) }

    // MARK: Jobs and notices (the consumers' side)

    /// Pops every queued job without finishing it (jobs stay in flight).
    public func popJobs() -> [InjectionJob] {
        var jobs: [InjectionJob] = []
        while let job = queue.pop() { jobs.append(job) }
        return jobs
    }

    /// Pops every queued job and finishes it as executed with nothing left in flight (the worker reported
    /// that nothing more will echo), recording `outcome` for keyUp pairing.
    @discardableResult
    public func completeJobs(outcome: JobOutcome = .executed) -> [InjectionJob] {
        let jobs = popJobs()
        for job in jobs {
            let sequence = Self.sequence(of: job)
            if case .edit = job { feedback.record(outcome, for: sequence) }
            queue.finished(sequence, expectation: nil)
        }
        return jobs
    }

    /// The job's own sequence.
    public static func sequence(of job: InjectionJob) -> JobSequence {
        switch job {
        case .edit(let edit): edit.sequence
        case .replay(let sequence, _), .pairedKeyUp(let sequence, _, _): sequence
        case .boundary(let boundary): boundary.sequence
        }
    }

    public func mainNotices() -> [MainNotice] {
        while let notice = outbox.toMain.pop() { mainReceived.append(notice) }
        return mainReceived
    }

    public func axNotices() -> [AXNotice] {
        while let notice = outbox.toAX.pop() { axReceived.append(notice) }
        return axReceived
    }
}
