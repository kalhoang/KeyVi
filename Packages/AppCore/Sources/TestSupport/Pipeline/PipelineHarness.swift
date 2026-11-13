// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The property harness behind `PipelineHarness` (13.1, ADR 0311): physical and posted events share one
// `SimulatedWindowServer` FIFO in front of the pipeline; what the pipeline passes reaches the field and the
// ledger; the reference consumer executes jobs and posts through a `FakeEventPoster`. Host steps publish
// snapshots the way the producers do. The harness also checks properties the ledger cannot see: fail-open
// passes everything in the same callback (PLT-R730), echoes pass unchanged and are never physical (PLT-R321),
// and the engine is reset before its next feed after every host transition (PLT-R210).

internal import AppModel
internal import Diagnostics
internal import Injection
public import InputHost
internal import RealtimeSupport
internal import Synchronization

/// Where the fake poster's sink puts posted events until the harness moves them into the server queue.
final class PostedInbox: Sendable {
    private let items = Mutex<[FakeEventPoster.Posted]>([])
    func append(_ posted: FakeEventPoster.Posted) { items.withLock { $0.append(posted) } }
    func drain() -> [FakeEventPoster.Posted] {
        items.withLock { items in
            defer { items.removeAll(keepingCapacity: true) }
            return items
        }
    }
}

/// What a run exercised, so the property suites can prove they are not vacuous.
public struct HarnessStatistics: Sendable, Hashable {
    public var outcomes: [EventOutcome: Int] = [:]
    public var editsDelivered = 0
    public var replaysDelivered = 0
    public var echoesSeen = 0
    public var discardedEdits = 0
    public var toggles = 0
    public var secureResumes = 0
    public var failOpenEvents = 0
    /// `MainNotice.postingBroken` sent: the echo-loss detection fired (PLT-R323, PLT-R730).
    public var postingBrokenNotices = 0

    public init() {}

    public mutating func add(_ other: HarnessStatistics) {
        outcomes.merge(other.outcomes, uniquingKeysWith: +)
        editsDelivered += other.editsDelivered
        replaysDelivered += other.replaysDelivered
        echoesSeen += other.echoesSeen
        discardedEdits += other.discardedEdits
        toggles += other.toggles
        secureResumes += other.secureResumes
        failOpenEvents += other.failOpenEvents
        postingBrokenNotices += other.postingBrokenNotices
    }
}

final class HarnessCore {
    let fixture: PipelineFixture
    let field: SimulatedTextField
    let ledger = ConservationLedger()
    private let layout: LayoutTable
    private let clock: ManualClock
    private let server: SimulatedWindowServer
    private let inbox = PostedInbox()
    private let poster: FakeEventPoster
    private var consumer: ReferenceJobConsumer?
    private(set) var mainNotices: [MainNotice] = []
    private(set) var statistics = HarnessStatistics()
    private var nextIndex = 0
    private var indexByTime: [UInt64: Int] = [:]
    private var focusGeneration: UInt64 = 1
    private var settingsGeneration: UInt64 = 1
    private var inputSourceGeneration: UInt64 = 1
    private var secureGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 1
    private var permissionGranted = true
    private var postingBrokenSeen = false
    private var reportedResetViolations = 0

    var metrics: PlatformMetrics { fixture.metrics }
    var engineLog: EngineEventLog { fixture.log }

    init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock, server mode: SimulatedWindowServer.Mode,
        policy: InFlightPolicy
    ) {
        self.field = field
        self.layout = layout
        self.clock = clock
        server = SimulatedWindowServer(mode: mode)
        let inbox = self.inbox
        poster = FakeEventPoster(sink: { inbox.append($0) })
        fixture = PipelineFixture(
            settings: Self.settings(generation: 1), inputSource: PipelineFixtures.inputSource(table: layout),
            policy: policy, clock: clock, log: EngineEventLog(keepsEntries: false))
        consumer = ReferenceJobConsumer(
            queue: fixture.queue, feedback: fixture.feedback, marker: fixture.marker, poster: poster,
            focusGeneration: fixture.focusGeneration, metrics: fixture.metrics, clock: clock,
            eventIndex: { [unowned self] in indexByTime[$0.nanoseconds] },
            onLost: { [unowned self] in ledger.lostWhilePostingBroken($0) },
            onPosted: { [unowned self] in movePostedIntoServer() })
    }

    func run(_ steps: [RandomEventGenerator.Step]) {
        for step in steps {
            perform(step)
            drainNotices()
        }
        settle()
        drainNotices()
        ledger.lostMetric(metrics.lostWhilePostingBroken.value)
        statistics.discardedEdits = consumer?.discardedEdits ?? 0
    }

    private func perform(_ step: RandomEventGenerator.Step) {
        switch step {
        case .key(let event): enqueuePhysical(event)
        case .focusChange: publishFocusChange()
        case .secureInput(let enabled):
            secureGeneration += 1
            fixture.publish(
                secureInput: SecureInputSnapshot(generation: secureGeneration, enabled: enabled, holder: nil))
            engineLog.mark()
        case .permission(let granted):
            permissionGranted = granted
            publishLifecycle()
        case .advanceMicroseconds(let microseconds): clock.advance(byMicroseconds: microseconds)
        case .workerRuns(let maxJobs):
            for _ in 0..<maxJobs {
                guard consumer?.runOne() == true else { break }
            }
        case .tapDrains(let maxEvents): deliver(server.drain(maxEvents: maxEvents))
        case .postingWorks(let works): setPosting(works)
        case .settingsChange: publishSettingsChange()
        case .inputSourceChange:
            inputSourceGeneration += 1
            fixture.publish(inputSource: PipelineFixtures.inputSource(generation: inputSourceGeneration, table: layout))
            engineLog.mark()
        }
    }

    /// Escape is the restore binding (PLT-R353) in every other generation; the engine revision changes in every
    /// third, so most settings changes keep the word (PRD-R27) and some build a fresh engine.
    static func settings(generation: UInt64) -> TapSettingsSnapshot {
        PipelineFixtures.settings(
            generation: generation, restore: generation % 2 == 1 ? .key(KeyCode(rawValue: 0x35)) : nil,
            engineRevision: generation / 3)
    }

    private func publishSettingsChange() {
        settingsGeneration += 1
        fixture.publish(settings: Self.settings(generation: settingsGeneration))
    }

    // MARK: Host steps

    /// A new focus owner every time (new pid or element), cycling through decisions that pause, pass through,
    /// type English or compose.
    private func publishFocusChange() {
        focusGeneration += 1
        let pid = Int32(100 + focusGeneration % 3)
        let focus: FocusSnapshot
        switch focusGeneration % 6 {
        case 0:
            focus = PipelineFixtures.focus(
                generation: focusGeneration, pid: pid, field: PipelineFixtures.field(secure: true))
        case 1:
            focus = PipelineFixtures.focus(
                generation: focusGeneration, pid: pid, decision: PipelineFixtures.decision(strategy: .passThrough))
        case 2: focus = PipelineFixtures.focus(generation: focusGeneration, pid: pid, mode: .english)
        case 3:
            focus = PipelineFixtures.focus(
                generation: focusGeneration, pid: pid, decision: PipelineFixtures.decision(requireTextFocus: .always),
                field: PipelineFixtures.field(editable: false))
        default: focus = PipelineFixtures.focus(generation: focusGeneration, pid: pid)
        }
        fixture.publish(focus: focus)
        engineLog.mark()
    }

    private func publishLifecycle() {
        lifecycleGeneration += 1
        fixture.publish(
            lifecycle: PipelineFixtures.lifecycle(
                generation: lifecycleGeneration, phase: permissionGranted ? .running : .failOpen(.permissionRevoked)))
        engineLog.mark()
    }

    /// The poster drops silently (permission revoked) or delivers again; recovery clears posting broken the
    /// way the lifecycle owner does (PLT-R731).
    private func setPosting(_ works: Bool) {
        poster.setMode(works ? .delivering : .silentlyDropping)
        ledger.postingWorks(works)
        guard works, fixture.feedback.isPostingBroken else { return }
        fixture.feedback.clearPostingBroken()
        publishLifecycle()
    }

    // MARK: Events through the server

    private func enqueuePhysical(_ event: RawKeyEvent) {
        server.enqueue(.physical(index: nextIndex, event))
        nextIndex += 1
        if server.mode == .immediate { deliver(server.drain(maxEvents: Int.max)) }
    }

    private func movePostedIntoServer() {
        for posted in inbox.drain() { server.enqueue(.posted(posted)) }
        if server.mode == .immediate { deliver(server.drain(maxEvents: Int.max)) }
    }

    private func deliver(_ pending: [SimulatedWindowServer.Pending]) {
        for item in pending {
            clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds + 1))  // unique receipt times
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
        if event.kind != .keyDown && event.kind != .keyUp && event.kind != .flagsChanged {
            if event.kind != .scrollWheel { engineLog.mark() }  // mouse down and tap re-enable are boundaries
            if fixture.pipeline.handle(event) != .pass { ledger.violation(index, "non-keyboard event swallowed") }
            return
        }
        let failingOpenBefore = !permissionGranted || fixture.feedback.isPostingBroken
        let verdict = fixture.pipeline.handle(event)
        let failingOpen = failingOpenBefore || fixture.feedback.isPostingBroken
        ledger.physical(index, event, outcome: fixture.pipeline.lastOutcome)
        if let outcome = fixture.pipeline.lastOutcome { statistics.outcomes[outcome, default: 0] += 1 }
        if failingOpen {
            statistics.failOpenEvents += 1
            ledger.processedWhileFailingOpen(index)
            if verdict != .pass { ledger.violation(index, "swallowed while failing open (PLT-R730)") }
        }
        if verdict == .pass {
            field.apply(Self.record(event), layout: layout)
            ledger.passedThrough(index)
        }
        checkTransitions(index)
    }

    private func deliverPosted(_ posted: FakeEventPoster.Posted) {
        let event = Self.event(posted, at: clock.now())
        if fixture.pipeline.handle(event) != .pass || fixture.pipeline.lastOutcome != nil {
            ledger.violation(-1, "an echo was not passed unchanged (PLT-R323)")
        }
        statistics.echoesSeen += 1
        switch posted {
        case .synthetic(let synthetic, let userData):
            field.apply(synthetic, layout: layout)
            if case .edit(let index?, true)? = consumer?.delivery(forUserData: userData) {
                statistics.editsDelivered += 1
                ledger.editDelivered(forEvent: index)
            }
        case .replay(let record, let userData):
            field.apply(record, layout: layout)
            if case .replay(let index?)? = consumer?.delivery(forUserData: userData) {
                statistics.replaysDelivered += 1
                ledger.delivered(record, asReplayOf: index)
            }
        }
    }

    private func checkTransitions(_ index: Int) {
        if fixture.feedback.isPostingBroken != postingBrokenSeen {
            postingBrokenSeen.toggle()
            engineLog.mark()
        }
        let violations = engineLog.resetViolations
        if violations > reportedResetViolations {
            reportedResetViolations = violations
            ledger.violation(index, "engine fed without a reset after a host transition (PLT-R210)")
        }
    }

    /// Drains the server and the queue and lets echo timeouts expire (a scroll event makes the tap settle).
    private func settle() {
        for _ in 0..<64 {
            deliver(server.drain(maxEvents: Int.max))
            while consumer?.runOne() == true { deliver(server.drain(maxEvents: Int.max)) }
            if fixture.queue.inFlight == 0 && server.count == 0 && consumer?.isIdle != false { return }
            clock.advance(byMicroseconds: 250_000)
            enqueuePhysical(GeneratorCore.event(.scrollWheel, keyCode: 0, flags: 0))
            deliver(server.drain(maxEvents: Int.max))
        }
        ledger.violation(-1, "the harness did not settle: \(fixture.queue.inFlight) jobs still in flight")
    }

    private func drainNotices() {
        while let notice = fixture.outbox.toMain.pop() {
            switch notice {
            case .modeToggled: statistics.toggles += 1
            case .secureInputResumedByKey: statistics.secureResumes += 1
            case .postingBroken: statistics.postingBrokenNotices += 1
            default: break
            }
            mainNotices.append(notice)
        }
        while fixture.outbox.toAX.pop() != nil {}
    }

    static func record(_ event: RawKeyEvent) -> KeyEventRecord {
        let kind: KeyEventRecord.Kind =
            switch event.kind {
            case .keyUp: .keyUp
            case .flagsChanged: .flagsChanged
            default: .keyDown
            }
        return KeyEventRecord(
            kind: kind, keyCode: event.keyCode, flags: event.flags, autorepeat: event.autorepeat,
            keyboardType: event.keyboardType, unicode: event.unicode, receivedAt: event.receivedAt, isProbe: false)
    }

    static func event(_ posted: FakeEventPoster.Posted, at time: MonotonicInstant) -> RawKeyEvent {
        switch posted {
        case .synthetic(let synthetic, let userData):
            RawKeyEvent(
                kind: synthetic.isKeyDown ? .keyDown : .keyUp, keyCode: synthetic.keyCode, flags: synthetic.flags,
                autorepeat: false, keyboardType: PipelineFixtures.keyboardType, unicode: synthetic.unicode,
                userData: userData, receivedAt: time)
        case .replay(let record, let userData):
            RawKeyEvent(
                kind: record.kind == .keyUp ? .keyUp : (record.kind == .flagsChanged ? .flagsChanged : .keyDown),
                keyCode: record.keyCode, flags: record.flags, autorepeat: record.autorepeat,
                keyboardType: record.keyboardType, unicode: record.unicode, userData: userData, receivedAt: time)
        }
    }
}
