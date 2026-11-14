// SPDX-License-Identifier: GPL-3.0-or-later
//
// Job builders and a worker rig for the injection tests. Every service is a fake; nothing posts real events.

import AppModel
import Diagnostics
import InputHost
import RealtimeSupport
import TestSupport

@testable import Injection

enum Fixture {
    static let start = MonotonicInstant(nanoseconds: 1_000_000_000)
    static let field = FieldHandle(pid: 42, token: 7, element: nil)
    static let triggerS = InjectionFieldWiring.keyDown("s", receivedAt: start)

    static func parameters(_ change: (inout InjectionParameters) -> Void = { _ in }) -> InjectionParameters {
        var parameters = InjectionParameters.defaults
        change(&parameters)
        return parameters
    }

    static func plan(
        _ strategy: InjectionStrategy = .backspaceReplace, parameters: InjectionParameters = .defaults,
        fallback: [InjectionStrategy] = [.passThrough]
    ) -> InjectionPlan {
        InjectionPlan(strategy: strategy, parameters: parameters, fallback: fallback)
    }

    static func job(
        sequence: UInt64 = 1, deleteCount: Int, deleteUTF16Count: Int? = nil, replaced: String? = nil,
        insertion: String, plan: InjectionPlan = Fixture.plan(), generation: UInt64 = 1, kind: EditKind = .compose,
        trigger: KeyEventRecord? = Fixture.triggerS, field: FieldHandle? = Fixture.field,
        createdAt: MonotonicInstant = Fixture.start, verifyBeforeApply: Bool = false,
        nearFocusChange: Bool = false, keyCodes: JobKeyCodes? = nil, isProbe: Bool = false
    ) -> EditJob {
        EditJob(
            sequence: JobSequence(rawValue: sequence), generation: FocusGeneration(rawValue: generation), plan: plan,
            field: field, kind: kind, deleteCount: deleteCount, deleteUTF16Count: deleteUTF16Count ?? deleteCount,
            replacedText: replaced, insertion: insertion,
            keyCodes: keyCodes
                ?? JobKeyCodes(trigger: trigger?.keyCode ?? KeyCode(rawValue: 0x01), paste: KeyCode(rawValue: 0x09)),
            trigger: trigger, verifyBeforeApply: verifyBeforeApply, wordStartedNearFocusChange: nearFocusChange,
            createdAt: createdAt, isProbe: isProbe)
    }
}

extension FakeEventPoster.Posted {
    var synthetic: SyntheticKeyEvent? {
        if case .synthetic(let event, _) = self { return event }
        return nil
    }

    var replayed: KeyEventRecord? {
        if case .replay(let record, _) = self { return record }
        return nil
    }
}

extension [FakeEventPoster.Posted] {
    var keyDowns: [SyntheticKeyEvent] { compactMap(\.synthetic).filter(\.isKeyDown) }
    var backspaceCount: Int { keyDowns.filter { $0.keyCode == .delete }.count }
    var insertedText: String { keyDowns.filter { $0.keyCode != .delete }.map(\.unicode.string).joined() }
}

/// A worker wired to fakes and a simulated field, driven with `runUntilIdle` on a `ManualClock`.
final class WorkerRig {
    let clock = ManualClock()
    let layout = InjectionTestLayouts.qwerty()
    let field: SimulatedTextField
    let poster: FakeEventPoster
    let fieldAccess: FakeFocusedFieldAccess
    let pasteboard: FakePasteboard
    let signal = WorkerSignal()
    let queue: JobQueue
    let feedback = WorkerFeedback()
    let marker = EventMarker(tag: 0xA1_B2C3_D4E5)
    let generation = CurrentFocusGeneration()
    let metrics = PlatformMetrics()
    let health = HealthEventLog()
    let logger = RecordingLogger()
    let worker: InjectionWorker

    init(
        field: SimulatedTextField = SimulatedTextField(), pasteboard: FakePasteboard = FakePasteboard(),
        policy: InFlightPolicy = .untilEcho, configuration: WorkerConfiguration = WorkerConfiguration(),
        poster: FakeEventPoster? = nil, fieldAccessWrapper: ((FakeFocusedFieldAccess) -> any FocusedFieldAccess)? = nil,
        capture: CaptureController? = nil
    ) {
        self.field = field
        self.pasteboard = pasteboard
        self.poster = poster ?? InjectionFieldWiring.poster(for: field, layout: layout)
        fieldAccess = FakeFocusedFieldAccess(field: field)
        queue = JobQueue(capacity: 512, signal: signal, policy: policy)
        generation.store(FocusGeneration(rawValue: 1))
        let services = InjectionServices(
            poster: self.poster, fieldAccess: fieldAccessWrapper?(fieldAccess) ?? fieldAccess, pasteboard: pasteboard,
            clock: clock, metrics: metrics,
            health: health, logger: logger, capture: capture)
        worker = InjectionWorker(
            queue: queue, signal: signal, feedback: feedback, marker: marker, focusGeneration: generation,
            services: services, configuration: configuration)
    }

    func nextSequence() -> UInt64 { queue.nextSequence().rawValue }

    @discardableResult
    func pushEdit(_ build: (UInt64) -> EditJob) -> UInt64 {
        let sequence = nextSequence()
        precondition(queue.push(.edit(build(sequence))))
        return sequence
    }

    @discardableResult
    func pushReplay(_ record: KeyEventRecord) -> UInt64 {
        let sequence = nextSequence()
        precondition(queue.push(.replay(JobSequence(rawValue: sequence), record)))
        return sequence
    }

    @discardableResult
    func pushPairedKeyUp(_ record: KeyEventRecord, forJob: UInt64) -> UInt64 {
        let sequence = nextSequence()
        let job = InjectionJob.pairedKeyUp(
            JobSequence(rawValue: sequence), record, forJob: JobSequence(rawValue: forJob))
        precondition(queue.push(job))
        return sequence
    }

    @discardableResult
    func pushBoundary(_ reason: BoundaryReason = .focusChanged) -> UInt64 {
        let sequence = nextSequence()
        let job = BoundaryJob(
            sequence: JobSequence(rawValue: sequence), reason: reason, generation: generation.load())
        precondition(queue.push(.boundary(job)))
        return sequence
    }

    func run() { worker.runUntilIdle() }

    /// Drains the worker's expectations (as the tap's `EchoTracker` would) and returns them.
    func drainExpectations() -> [EchoExpectation] {
        var drained: [EchoExpectation] = []
        while let expectation = queue.expectations.pop() { drained.append(expectation) }
        queue.settleByTap(drained.count)
        return drained
    }

    func healthKinds() -> [HealthEvent.Kind] { health.recent(limit: 256).map(\.kind) }
    func outcome(_ sequence: UInt64) -> JobOutcome? { feedback.outcome(of: JobSequence(rawValue: sequence)) }
}
