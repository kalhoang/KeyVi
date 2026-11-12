// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pipeline property-test support (13.1): scripted engine, simulated text field, deterministic harness,
// conservation ledger and seeded event generator.

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

/// Text field model: caret, selection, inline-completion suggestion, secure flag, per-event processing,
/// optional asynchronous reordering. Applies synthetic and replayed events exactly as a Cocoa field would.
public final class SimulatedTextField: Sendable {
    public enum Behaviour: Sendable, Hashable {
        case cocoa
        case inlineCompletion(suggestions: [String])  // address bar, Spotlight, Sheets
        case dropsFirstEventAfterFocus  // edit-mode transition
        case ignoresUnicodePayload  // remote clients: types keycode letters
        case terminalReadsInBatches(maxEventsPerRead: Int)
    }

    public init(behaviour: Behaviour = .cocoa) { unimplemented() }
    public var text: String { unimplemented() }
    public var selection: TextRange { unimplemented() }
    public func apply(_ event: SyntheticKeyEvent) { unimplemented() }
    public func apply(_ record: KeyEventRecord, layout: LayoutTable) { unimplemented() }
    public func click(at offset: Int) { unimplemented() }
    public func reset() { unimplemented() }
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
    /// Exactly one outcome per physical keyboard event, replays once and in order, keyUp pairing (PLT-R313).
    public func violations() -> [Violation] { unimplemented() }
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
    }

    public init(seed: UInt64) { unimplemented() }
    public mutating func sequence(length: Int) -> [Step] { unimplemented() }
}

/// Wires a `KeyPipeline<ScriptedEngineFactory, ManualClock>` and an `InjectionWorker` in deterministic mode
/// to a `FakeEventPoster` whose events loop back into the pipeline as echoes and into a `SimulatedTextField`.
public final class PipelineHarness {
    public init(field: SimulatedTextField, layout: LayoutTable, clock: ManualClock) { unimplemented() }
    public func run(_ steps: [RandomEventGenerator.Step]) { unimplemented() }
    public var ledger: ConservationLedger { unimplemented() }
    public var field: SimulatedTextField { unimplemented() }
}
