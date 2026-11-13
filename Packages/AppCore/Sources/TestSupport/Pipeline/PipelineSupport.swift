// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pipeline property-test support (13.1): scripted engine, window-server queue model, deterministic harness,
// conservation ledger and seeded event generator. Workstream W1-F1. `SimulatedTextField` and the injection
// fakes live in Fakes/Common and Fakes/Injection (implemented in the skeleton, ADR 0313).

internal import AppModel
public import Injection
public import InputHost
internal import RealtimeSupport
public import VietnameseEngine

/// Scripted engine: maps typed characters to edits with a tiny Telex-like table (aa -> â, s -> acute on the
/// last vowel, w -> ư), enough to exercise deletes and inserts without the real engine.
public struct ScriptedEngine: CompositionEngine {
    public init() { unimplemented() }
    public mutating func handle(_ event: EngineEvent) -> EngineOutput { unimplemented() }
    public var activeDisplay: String { unimplemented() }
}

public struct ScriptedEngineFactory: CompositionEngineFactory {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> ScriptedEngine { ScriptedEngine() }
}

/// What happened to each physical event (PLT-R312).
public final class ConservationLedger: Sendable {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var eventIndex: Int
        public var reason: String
        public var description: String { "event \(eventIndex): \(reason)" }
    }

    public init() { unimplemented() }
    public func physical(_ index: Int, _ event: RawKeyEvent, outcome: EventOutcome?) { unimplemented() }
    public func delivered(_ record: KeyEventRecord, asReplayOf index: Int) { unimplemented() }
    public func passedThrough(_ index: Int) { unimplemented() }
    /// The event's replay or edit was posted while the poster was `.silentlyDropping` (ADR 0311): allowed only
    /// after posting broke, and the total must equal `PlatformMetrics.lostWhilePostingBroken`.
    public func lostWhilePostingBroken(_ index: Int) { unimplemented() }
    /// Exactly one outcome per physical keyboard event, replays once and in order, keyUp pairing (PLT-R313).
    /// Conservation is checked only while posting works; losses after posting broke are counted, never silent.
    public func violations() -> [Violation] { unimplemented() }
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

    public init(mode: Mode) { unimplemented() }
    public func enqueue(_ pending: Pending) { unimplemented() }
    public func drain(maxEvents: Int) -> [Pending] { unimplemented() }
    public var count: Int { unimplemented() }
}

/// Seeded random interleavings of keys, mouse downs, focus changes, tap-disabled events, secure-input
/// toggles and permission changes (section 3 acceptance: 100,000 sequences).
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
    }

    public init(seed: UInt64) { unimplemented() }
    public mutating func sequence(length: Int) -> [Step] { unimplemented() }
}

/// Wires a `KeyPipeline<ScriptedEngineFactory, ManualClock>` and a job consumer (W1-F1: a reference consumer;
/// W2-A: the real `InjectionWorker` in step mode) to a `FakeEventPoster` whose events go through a
/// `SimulatedWindowServer` back into the pipeline (echoes) and on into a `SimulatedTextField`.
public final class PipelineHarness {
    public init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock,
        server: SimulatedWindowServer.Mode = .immediate
    ) { unimplemented() }
    public func run(_ steps: [RandomEventGenerator.Step]) { unimplemented() }
    public var ledger: ConservationLedger { unimplemented() }
    public var field: SimulatedTextField { unimplemented() }
}
