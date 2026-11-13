// SPDX-License-Identifier: LicenseRef-App-Pending
//
// How the engine is bridged (docs/decisions/0306-engine-bridge.md). The engine is a pure value type
// (`Engine.reduce`, 01-engine.md 12.2); the host keeps one `Session` on the tap thread and swaps engines only
// at hard boundaries (ENG-R1211). Engines are prebuilt off the hot path, one per variant.

internal import AppModel
public import SettingsStore
public import VietnameseEngine

/// Abstraction the pipeline is generic over, so conservation and ordering property tests can drive it with a
/// scripted fake engine independently of the engine track (13.1).
public protocol CompositionEngine {
    mutating func handle(_ event: EngineEvent) -> EngineOutput
    /// Display of the active token before the event (for `EditJob.replacedText`, PLT-R402).
    var activeDisplay: String { get }
}

public protocol CompositionEngineFactory {
    associatedtype Engine: CompositionEngine
    /// Called on the tap thread at a hard boundary; MUST NOT allocate beyond copying prebuilt values.
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> Engine
}

/// Production engine: a `VietnameseEngine.Session` over a prebuilt `Engine`.
public struct VietnameseCompositionEngine: CompositionEngine {
    public private(set) var session: Session
    public init(engine: VietnameseEngine.Engine) { session = Session(engine: engine) }
    public mutating func handle(_ event: EngineEvent) -> EngineOutput { session.handle(event) }
    public var activeDisplay: String { session.state.activeDisplay }
}

public struct VietnameseCompositionEngineFactory: CompositionEngineFactory {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> VietnameseCompositionEngine {
        VietnameseCompositionEngine(engine: settings.engines.engine(for: variant))
    }
}

/// Eight prebuilt engines: appContext x englishRestore x macros (ENG-R850, `features`, ENG-R1107).
public struct EngineCatalog: Sendable {
    public init(engines: [EngineVariant: VietnameseEngine.Engine]) { unimplemented() }
    public func engine(for variant: EngineVariant) -> VietnameseEngine.Engine { unimplemented() }
}

public enum MacroTableBuildIssue: Sendable, Hashable {
    case rejected(macroID: String, reason: MacroTable.ValidationError)
}

/// Pure mapping from settings to engine values. Runs on the utility queue when settings change.
public enum EngineBridge {
    /// D1, D2, D4, D5, D6 plus the variant.
    public static func configuration(for settings: EffectiveSettings, variant: EngineVariant) -> EngineConfiguration {
        unimplemented()
    }

    /// Enabled macros only; invalid entries are skipped and reported (the editor prevents them, PRD-R29).
    public static func macroTable(from macros: [StoredMacro]) -> (MacroTable, [MacroTableBuildIssue]) {
        unimplemented()
    }

    /// Loads bundled lexicons once (ENG-R1231: at most 50 ms) and attaches user lists and macros.
    public static func resources(
        settings: EffectiveSettings, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources { unimplemented() }

    public static func catalog(settings: EffectiveSettings, resources: Resources) -> EngineCatalog { unimplemented() }
}
