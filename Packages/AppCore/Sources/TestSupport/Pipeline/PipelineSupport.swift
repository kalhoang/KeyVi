// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pipeline property-test support (13.1): scripted engine, window-server queue model, deterministic harness,
// conservation ledger and seeded event generator. Workstream W1-F1. `SimulatedTextField` and the injection
// fakes live in Fakes/Common and Fakes/Injection (implemented in the skeleton, ADR 0313). The logic lives in
// the files next to this one (ScriptedEngine, ConservationLedger, RandomEventGenerator, PipelineHarness,
// ReferenceJobConsumer, PipelineFixtures); this file is the public surface.

internal import AppModel
public import Diagnostics
public import Injection
public import InputHost
internal import RealtimeSupport
public import VietnameseEngine

/// Scripted engine: maps typed characters to edits with a tiny Telex-like table (aa -> â, s -> acute on the
/// last vowel, w -> ư), enough to exercise deletes and inserts without the real engine. Rules in
/// `ScriptedComposer`.
public struct ScriptedEngine: CompositionEngine {
    private var composer = ScriptedComposer()
    private let log: EngineEventLog?

    public init() { log = nil }
    init(log: EngineEventLog?) { self.log = log }

    public mutating func handle(_ event: EngineEvent) -> EngineOutput {
        log?.handled(event)
        return composer.handle(event)
    }

    public var activeDisplay: String { composer.display }
}

/// Uses the reference recogniser so the suites run before W1-E's `HotkeyRecognizer` lands; switch `Hotkeys`
/// to `HotkeyRecognizer` to run them against the production recogniser.
public struct ScriptedEngineFactory: CompositionEngineFactory, Sendable {
    public typealias Hotkeys = ReferenceHotkeyRecognizer
    public let log: EngineEventLog?

    public init() { log = nil }
    public init(log: EngineEventLog) { self.log = log }

    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> ScriptedEngine {
        log?.made(variant)
        return ScriptedEngine(log: log)
    }
}

/// What happened to each physical event (PLT-R312). The harness reports every physical keyboard event with its
/// tap outcome and every delivery to the field; `violations()` checks the rules in `LedgerState`.
public final class ConservationLedger: Sendable {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var eventIndex: Int
        public var reason: String
        public var description: String { "event \(eventIndex): \(reason)" }
    }

    private let state = Mutex(LedgerState())

    public init() {}
    public func physical(_ index: Int, _ event: RawKeyEvent, outcome: EventOutcome?) {
        state.withLock { $0.physical(index, event, outcome: outcome) }
    }
    public func delivered(_ record: KeyEventRecord, asReplayOf index: Int) {
        state.withLock { $0.delivered(record, asReplayOf: index) }
    }
    public func passedThrough(_ index: Int) { state.withLock { $0.passedThrough(index) } }
    /// The event's replay or edit was posted while the poster was `.silentlyDropping` (ADR 0311): allowed only
    /// after posting broke, and the total must equal `PlatformMetrics.lostWhilePostingBroken`.
    public func lostWhilePostingBroken(_ index: Int) { state.withLock { $0.lost(index) } }
    /// The edit job created for the physical event `index` reached the field (its final event passed the tap).
    public func editDelivered(forEvent index: Int) { state.withLock { $0.editDelivered(index) } }
    /// The event was processed while the tap was failing open: it must pass (PLT-R730); its keyUp pairing and
    /// ordering are not checked, because fail-open stops holding by design.
    public func processedWhileFailingOpen(_ index: Int) { state.withLock { $0.failingOpen(index) } }
    /// The poster stopped (false) or resumed (true) delivering. Losses are allowed only while it does not.
    public func postingWorks(_ works: Bool) { state.withLock { $0.postingWorks(works) } }
    /// `PlatformMetrics.lostWhilePostingBroken` at the end of the run.
    public func lostMetric(_ value: UInt64) { state.withLock { $0.lostMetric = value } }
    /// A property the harness checks itself (fail-open, echo handling, PLT-R210 resets).
    public func violation(_ index: Int, _ reason: String) { state.withLock { $0.extra(index, reason) } }
    /// Exactly one outcome per physical keyboard event, replays once and in order, keyUp pairing (PLT-R313).
    /// Conservation is checked only while posting works; losses after posting broke are counted, never silent.
    public func violations() -> [Violation] { state.withLock { $0.violations() } }
}

/// Model of the WindowServer event queue between the HID system or `CGEventPost` and the session tap
/// (ADR 0311). Physical events and posted synthetic events enter one FIFO and reach the tap in that order;
/// what the tap passes reaches the field. In `.lagging` mode physical events wait in the queue until a
/// `.tapDrains` step, so a key typed before the worker posted reaches the tap after the posting finished: the
/// case that a "posted = done" definition of in flight gets wrong (`serverQueueLag` in the review).
public final class SimulatedWindowServer {
    public enum Mode: Sendable, Hashable {
        /// The tap receives each event as soon as it is enqueued.
        case immediate
        /// Events wait until the harness runs a `.tapDrains` step.
        case lagging
    }

    public enum Pending: Sendable {
        case physical(index: Int, RawKeyEvent)
        case posted(FakeEventPoster.Posted)
    }

    public let mode: Mode
    private var queue: [Pending] = []
    private var head = 0

    public init(mode: Mode) { self.mode = mode }
    public func enqueue(_ pending: Pending) { queue.append(pending) }
    public func drain(maxEvents: Int) -> [Pending] {
        let end = head + min(max(0, maxEvents), queue.count - head)
        let drained = Array(queue[head..<end])
        head = end
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        return drained
    }
    public var count: Int { queue.count - head }
}

/// Seeded random interleavings of keys, chords, mouse downs, focus, settings and input-source changes,
/// tap-disabled events, secure-input toggles and permission changes (section 3 acceptance: 100,000 sequences). Rules in `GeneratorCore`.
public struct RandomEventGenerator: Sendable {
    public enum Step: Sendable, Hashable {
        case key(RawKeyEvent)
        case focusChange
        case secureInput(Bool)
        case permission(Bool)
        case advanceMicroseconds(UInt64)
        case workerRuns(maxJobs: Int)
        /// The tap receives up to `maxEvents` queued events (meaningful with `SimulatedWindowServer.Mode.lagging`).
        case tapDrains(maxEvents: Int)
        /// The poster starts or stops dropping silently (permission revoked mid-sequence, ADR 0311).
        case postingWorks(Bool)
        /// A new settings generation (PLT-R1008): the restore binding and the engine revision vary.
        case settingsChange
        /// A new input-source generation with the same layout (PLT-R340).
        case inputSourceChange
    }

    private var core: GeneratorCore

    public init(seed: UInt64) { core = GeneratorCore(seed: seed, includePostingBreaks: false) }
    /// `includePostingBreaks` adds `.postingWorks` steps (the posting-broken suite).
    public init(seed: UInt64, includePostingBreaks: Bool) {
        core = GeneratorCore(seed: seed, includePostingBreaks: includePostingBreaks)
    }
    public mutating func sequence(length: Int) -> [Step] { core.sequence(length: length) }
}

/// Wires a `KeyPipeline<ScriptedEngineFactory, ManualClock>` and a job consumer (W1-F1: a reference consumer;
/// W2-A: the real `InjectionWorker` in step mode) to a `FakeEventPoster` whose events go through a
/// `SimulatedWindowServer` back into the pipeline (echoes) and on into a `SimulatedTextField`. `run` executes
/// the steps, then settles: it drains the server and the queue and lets echo timeouts expire, so the ledger
/// sees every delivery.
public final class PipelineHarness {
    private let core: HarnessCore

    public init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock,
        server: SimulatedWindowServer.Mode = .immediate
    ) {
        core = HarnessCore(field: field, layout: layout, clock: clock, server: server, policy: .untilEcho)
    }
    /// `policy: .untilPosted` is the self-check of ADR 0311: with `.lagging` it must produce ordering violations.
    public init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock, server: SimulatedWindowServer.Mode,
        policy: InFlightPolicy
    ) {
        core = HarnessCore(field: field, layout: layout, clock: clock, server: server, policy: policy)
    }
    public func run(_ steps: [RandomEventGenerator.Step]) { core.run(steps) }
    public var ledger: ConservationLedger { core.ledger }
    public var field: SimulatedTextField { core.field }
    public var metrics: PlatformMetrics { core.metrics }
    public var engineLog: EngineEventLog { core.engineLog }
    /// Notices the pipeline sent to the main thread, drained after every step.
    public var mainNotices: [MainNotice] { core.mainNotices }
    public var statistics: HarnessStatistics { core.statistics }
}
