// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The combined property harness of W2-A (02-platform.md 13.1): the W1-F1 setup (physical and posted events in
// one `SimulatedWindowServer` FIFO in front of the pipeline, a `ConservationLedger`, seeded steps) with the
// REAL `InjectionWorker` in step mode instead of the reference consumer, and the scripted or the real engine.
//
// The real worker does not say which physical key an edit belongs to, so the harness attributes deliveries:
// replays by the `receivedAt` they carry; edits by the worker's capture records, which name the job right after
// its final event was posted, and the pipeline's consumed-key table, which names the job of each trigger.
// Workstream W2-A.

import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import Synchronization
import TestSupport
import VietnameseEngine

@testable import InputHost

/// The poster the worker posts through: every call (delivered or dropped) is recorded in order, after the
/// capture records written so far were read, so a job's events are known when its record shows up.
final class TracingPoster: EventPoster, Sendable {
    enum Item {
        case synthetic(SyntheticKeyEvent, userData: Int64, delivered: Bool)
        case replay(KeyEventRecord, userData: Int64, delivered: Bool)
        /// The worker finished edit job `sequence` (its capture record) before the next post.
        case jobFinished(sequence: UInt64)
    }

    private let dropping = Atomic<Bool>(false)
    private let capture: CaptureController
    private let items = Mutex<[Item]>([])

    init(capture: CaptureController) { self.capture = capture }

    func setDropping(_ value: Bool) { dropping.store(value, ordering: .sequentiallyConsistent) }

    func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) {
        append(.synthetic(event, userData: userData, delivered: !dropping.load(ordering: .sequentiallyConsistent)))
    }

    func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) {
        append(.replay(record, userData: userData, delivered: !dropping.load(ordering: .sequentiallyConsistent)))
    }

    /// Everything posted and finished since the last call, in order.
    func take() -> [Item] {
        readRecords()
        return items.withLock { items in
            defer { items.removeAll(keepingCapacity: true) }
            return items
        }
    }

    private func append(_ item: Item) {
        readRecords()
        items.withLock { $0.append(item) }
    }

    /// The worker pushes an edit job's record right after the job's last post, so reading the records before
    /// every post puts each one between its job's events and the next job's (the harness is single-threaded).
    private func readRecords() {
        while let record = capture.injectRecords.pop() {
            if case .job(let sequence, _, _, _) = record {
                items.withLock { $0.append(.jobFinished(sequence: sequence)) }
            }
        }
    }
}

/// What a combined run exercised (non-vacuity) besides the ledger.
struct CombinedStatistics {
    var editsDelivered = 0
    var replaysDelivered = 0
    var held = 0
    var flushes: UInt64 = 0
    var generationDiscards = 0
    var postingBrokenNotices = 0
    /// Keys consumed with an empty edit (real engine only; ADR 0306 decision 4).
    var noOpEdits = 0

    mutating func add(_ other: CombinedStatistics) {
        noOpEdits += other.noOpEdits
        editsDelivered += other.editsDelivered
        replaysDelivered += other.replaysDelivered
        held += other.held
        flushes += other.flushes
        generationDiscards += other.generationDiscards
        postingBrokenNotices += other.postingBrokenNotices
    }
}

final class CombinedHarness<Factory: CompositionEngineFactory> {
    typealias Pipeline = KeyPipeline<Factory, ManualClock>

    let ledger = ConservationLedger()
    let field = SimulatedTextField()
    private(set) var statistics = CombinedStatistics()
    private let clock = ManualClock()
    private let layout = PipelineFixtures.qwertyTable()
    private let server: SimulatedWindowServer
    private let snapshots: TapSnapshots
    private let queue: JobQueue
    private let feedback = WorkerFeedback()
    private let marker = EventMarker(tag: 0x5A_5A5A_5A5A)
    private let outbox = TapOutbox(
        toMain: SPSCRing(capacity: 1_024), toAX: SPSCRing(capacity: 1_024), mainSignal: PipelineFixtures.wakeSignal,
        axSignal: PipelineFixtures.wakeSignal)
    private let metrics = PlatformMetrics()
    private let health = HealthEventLog(capacity: 4_096)
    private let focusGeneration = CurrentFocusGeneration()
    private let capture: CaptureController
    private let engineLog: EngineEventLog?
    private let settingsFor: (UInt64) -> TapSettingsSnapshot
    private let poster: TracingPoster
    private var pipeline: Pipeline!
    private var worker: InjectionWorker!

    private var nextIndex = 0
    private var indexByTime: [UInt64: Int] = [:]
    private var generationOfIndex: [Int: UInt64] = [:]
    private var triggerOfJob: [UInt64: Int] = [:]
    private var pendingFinal: [Int64: Int] = [:]
    private var lastSynthetic: (userData: Int64, delivered: Bool)?
    private var focus: UInt64 = 1
    private var settingsGeneration: UInt64 = 1
    private var inputSourceGeneration: UInt64 = 1
    private var secureGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 1
    private var permissionGranted = true
    private var postingBrokeInRun = false
    /// Keys the engine consumed with an empty edit: no job, nothing to deliver (ADR 0306 decision 4).
    private var noOpEdits: Set<Int> = []

    /// `settingsFor(generation)`: the settings snapshot of each generation (its engine catalog and revision).
    init(
        factory: Factory, server mode: SimulatedWindowServer.Mode, engineLog: EngineEventLog?,
        policy: InFlightPolicy = .untilEcho, settingsFor: @escaping (UInt64) -> TapSettingsSnapshot
    ) {
        server = SimulatedWindowServer(mode: mode)
        self.engineLog = engineLog
        self.settingsFor = settingsFor
        let epoch = ReaderEpoch()
        let focusSnapshot = PipelineFixtures.focus(generation: 1, pid: 101)
        snapshots = TapSnapshots(
            epoch: epoch, settings: SnapshotCell(settingsFor(1), epoch: epoch),
            focus: SnapshotCell(focusSnapshot, epoch: epoch),
            inputSource: SnapshotCell(PipelineFixtures.inputSource(table: layout), epoch: epoch),
            secureInput: SnapshotCell(.initial, epoch: epoch),
            lifecycle: SnapshotCell(PipelineFixtures.lifecycle(), epoch: epoch))
        let signal = WorkerSignal()
        queue = JobQueue(signal: signal, policy: policy)
        focusGeneration.store(focusSnapshot.generation)
        let captureClock = ManualClock()
        capture = CaptureController(
            directory: URL(fileURLWithPath: "/captures", isDirectory: true), fileSystem: InMemoryFileSystem(),
            wallClock: FixedWallClock(), clock: captureClock, scheduler: ManualScheduler(clock: captureClock))
        _ = try? capture.start(duration: CaptureLimits.maximumDuration)
        poster = TracingPoster(capture: capture)
        let context = PipelineContext(
            snapshots: snapshots, queue: queue, feedback: feedback, echo: EchoTracker(queue: queue), marker: marker,
            outbox: outbox, metrics: metrics, tapLog: TapLogRing(), capture: nil,
            watchdog: CallbackWatchdog(activitySignal: nil))
        pipeline = Pipeline(context: context, factory: factory, clock: clock)
        worker = InjectionWorker(
            queue: queue, signal: signal, feedback: feedback, marker: marker, focusGeneration: focusGeneration,
            services: InjectionServices(
                poster: poster, fieldAccess: FakeFocusedFieldAccess(field: field), pasteboard: FakePasteboard(),
                clock: clock, metrics: metrics, health: health, logger: RecordingLogger(), capture: capture))
    }

    func run(_ steps: [RandomEventGenerator.Step]) {
        for step in steps {
            perform(step)
            drainNotices()
        }
        settle()
        drainNotices()
        statistics.flushes = metrics.flushes.value
        statistics.generationDiscards = health.recent(limit: 4_096).filter { $0.kind == .generationDiscard }.count
        statistics.noOpEdits = noOpEdits.count
        attributeWorkerLosses()
    }

    // MARK: Steps

    private func perform(_ step: RandomEventGenerator.Step) {
        switch step {
        case .key(let event): enqueuePhysical(event)
        case .focusChange: publishFocusChange()
        case .secureInput(let enabled):
            secureGeneration += 1
            snapshots.secureInput.publish(
                SecureInputSnapshot(generation: secureGeneration, enabled: enabled, holder: nil))
            engineLog?.mark()
        case .permission(let granted):
            permissionGranted = granted
            publishLifecycle()
        case .advanceMicroseconds(let microseconds): clock.advance(byMicroseconds: microseconds)
        case .workerRuns(let maxJobs): if maxJobs > 0 { runWorker() }
        case .tapDrains(let maxEvents): deliver(server.drain(maxEvents: maxEvents))
        case .postingWorks(let works): setPosting(works)
        case .settingsChange:
            settingsGeneration += 1
            snapshots.settings.publish(settingsFor(settingsGeneration))
        case .inputSourceChange:
            inputSourceGeneration += 1
            snapshots.inputSource.publish(
                PipelineFixtures.inputSource(generation: inputSourceGeneration, table: layout))
            engineLog?.mark()
        }
    }

    /// A new focus owner each time, cycling through secure, pass-through, English and composing decisions.
    private func publishFocusChange() {
        focus += 1
        let pid = Int32(100 + focus % 3)
        let snapshot: FocusSnapshot
        switch focus % 6 {
        case 0:
            snapshot = PipelineFixtures.focus(generation: focus, pid: pid, field: PipelineFixtures.field(secure: true))
        case 1:
            snapshot = PipelineFixtures.focus(
                generation: focus, pid: pid, decision: PipelineFixtures.decision(strategy: .passThrough))
        case 2: snapshot = PipelineFixtures.focus(generation: focus, pid: pid, mode: .english)
        default: snapshot = PipelineFixtures.focus(generation: focus, pid: pid)
        }
        snapshots.focus.publish(snapshot)
        focusGeneration.store(snapshot.generation)
        engineLog?.mark()
    }

    private func publishLifecycle() {
        lifecycleGeneration += 1
        snapshots.lifecycle.publish(
            PipelineFixtures.lifecycle(
                generation: lifecycleGeneration, phase: permissionGranted ? .running : .failOpen(.permissionRevoked)))
        engineLog?.mark()
    }

    /// The poster drops silently (permission revoked) or delivers again; recovery clears posting broken the way
    /// the lifecycle owner does (PLT-R731).
    private func setPosting(_ works: Bool) {
        poster.setDropping(!works)
        ledger.postingWorks(works)
        if !works { postingBrokeInRun = true }
        guard works, feedback.isPostingBroken else { return }
        feedback.clearPostingBroken()
        publishLifecycle()
    }

    // MARK: Worker and attribution

    private func runWorker() {
        worker.runUntilIdle()
        routePosted()
    }

    /// Moves what the worker posted into the server, attributing each finished edit to its trigger.
    private func routePosted() {
        for item in poster.take() {
            switch item {
            case .synthetic(let event, let userData, let delivered):
                lastSynthetic = (userData, delivered)
                if delivered { server.enqueue(.posted(.synthetic(event, userData: userData))) }
            case .replay(let record, let userData, let delivered):
                if delivered {
                    server.enqueue(.posted(.replay(record, userData: userData)))
                } else if let index = indexByTime[record.receivedAt.nanoseconds] {
                    ledger.lostWhilePostingBroken(index)
                    deliveredIndices.insert(index)
                }
            case .jobFinished(let sequence):
                finishEdit(sequence)
            }
        }
        if server.mode == .immediate { deliver(server.drain(maxEvents: Int.max)) }
    }

    /// Edit job `sequence` finished; `lastSynthetic` (if any) was its final event.
    private func finishEdit(_ sequence: UInt64) {
        let last = lastSynthetic
        lastSynthetic = nil
        guard let index = triggerOfJob.removeValue(forKey: sequence), let last else { return }
        // PLT-R316: an edit is applied only to the focus generation of its trigger.
        if generationOfIndex[index] != focusGeneration.load().rawValue {
            ledger.violation(index, "edit applied after its focus generation changed (PLT-R316)")
        }
        if last.delivered {
            pendingFinal[last.userData] = index
        } else {
            ledger.lostWhilePostingBroken(index)
            deliveredIndices.insert(index)
        }
    }

    /// Events the worker knowingly did not post while posting was broken are counted in the metric, not posted;
    /// they are attributed here (runs with posting breaks only; ADR 0308, ADR 0311).
    private func attributeWorkerLosses() {
        guard postingBrokeInRun else { return }
        for (index, _) in unaccounted() { ledger.lostWhilePostingBroken(index) }
    }

    private var outcomes: [Int: EventOutcome] = [:]
    private var deliveredIndices: Set<Int> = []

    private func unaccounted() -> [(Int, EventOutcome)] {
        outcomes.filter { index, outcome in
            (outcome == .held || outcome == .consumedForEdit) && !deliveredIndices.contains(index)
                && !noOpEdits.contains(index)
        }.sorted { $0.key < $1.key }
    }

    /// The ledger's violations, except the one a no-op edit must produce: a key the engine consumed with an empty
    /// edit has no job and is delivered by nothing, which the ledger reports with exactly this reason (and any
    /// delivery of such a key would change the reason, so it still fails).
    var violations: [ConservationLedger.Violation] {
        ledger.violations().filter { violation in
            !(noOpEdits.contains(violation.eventIndex) && violation.reason == Self.noOpReason)
        }
    }

    static var noOpReason: String { "consumed for an edit but edits 0, replays 0, lost 0" }

    // MARK: Events through the server

    private func enqueuePhysical(_ event: RawKeyEvent) {
        server.enqueue(.physical(index: nextIndex, event))
        nextIndex += 1
        if server.mode == .immediate { deliver(server.drain(maxEvents: Int.max)) }
    }

    private func deliver(_ pending: [SimulatedWindowServer.Pending]) {
        for item in pending {
            clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds + 1))
            switch item {
            case .physical(let index, let event): deliverPhysical(index, event)
            case .posted(let posted): deliverPosted(posted)
            }
        }
    }

    private func deliverPhysical(_ index: Int, _ event: RawKeyEvent) {
        var event = event
        event.receivedAt = clock.now()
        indexByTime[event.receivedAt.nanoseconds] = index
        generationOfIndex[index] = focusGeneration.load().rawValue
        guard event.kind == .keyDown || event.kind == .keyUp || event.kind == .flagsChanged else {
            if event.kind != .scrollWheel { engineLog?.mark() }
            if pipeline.handle(event) != .pass { ledger.violation(index, "non-keyboard event swallowed") }
            return
        }
        let failingOpenBefore = !permissionGranted || feedback.isPostingBroken
        let verdict = pipeline.handle(event)
        let outcome = pipeline.lastOutcome
        ledger.physical(index, event, outcome: outcome)
        if let outcome { outcomes[index] = outcome }
        if outcome == .held { statistics.held += 1 }
        if outcome == .consumedForEdit {
            switch pipeline.consumedKeys.entry(event.keyCode) {
            case .job(let sequence): triggerOfJob[sequence.rawValue] = index
            case .withoutJob: noOpEdits.insert(index)
            case .none, .hotkey: break
            }
        }
        if failingOpenBefore || feedback.isPostingBroken {
            ledger.processedWhileFailingOpen(index)
            if verdict != .pass { ledger.violation(index, "swallowed while failing open (PLT-R730)") }
        }
        if verdict == .pass {
            field.apply(PipelineHarnessEvents.record(event), layout: layout)
            ledger.passedThrough(index)
            deliveredIndices.insert(index)
        }
        if let engineLog, engineLog.resetViolations > 0 {
            ledger.violation(index, "engine fed without a reset after a host transition (PLT-R210)")
        }
    }

    private func deliverPosted(_ posted: FakeEventPoster.Posted) {
        let event = PipelineHarnessEvents.event(posted, at: clock.now())
        if pipeline.handle(event) != .pass || pipeline.lastOutcome != nil {
            ledger.violation(-1, "an echo was not passed unchanged (PLT-R323)")
        }
        switch posted {
        case .synthetic(let synthetic, let userData):
            field.apply(synthetic, layout: layout)
            if let index = pendingFinal.removeValue(forKey: userData) {
                statistics.editsDelivered += 1
                deliveredIndices.insert(index)
                ledger.editDelivered(forEvent: index)
            }
        case .replay(let record, _):
            field.apply(record, layout: layout)
            if let index = indexByTime[record.receivedAt.nanoseconds] {
                statistics.replaysDelivered += 1
                deliveredIndices.insert(index)
                ledger.delivered(record, asReplayOf: index)
            }
        }
    }

    /// Drains the server and the worker and lets echo timeouts expire (a scroll event makes the tap settle).
    private func settle() {
        for _ in 0..<64 {
            deliver(server.drain(maxEvents: Int.max))
            runWorker()
            deliver(server.drain(maxEvents: Int.max))
            if queue.inFlight == 0 && server.count == 0 && queue.queuedCount == 0 { return }
            clock.advance(byMicroseconds: 250_000)
            enqueuePhysical(
                RawKeyEvent(
                    kind: .scrollWheel, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false,
                    keyboardType: PipelineFixtures.keyboardType, unicode: .empty, userData: 0,
                    receivedAt: clock.now()))
            deliver(server.drain(maxEvents: Int.max))
        }
        ledger.violation(-1, "liveness: the harness did not settle, \(queue.inFlight) jobs still in flight (PLT-R314)")
    }

    private func drainNotices() {
        while let notice = outbox.toMain.pop() {
            if case .postingBroken = notice { statistics.postingBrokenNotices += 1 }
        }
        while outbox.toAX.pop() != nil {}
    }
}
