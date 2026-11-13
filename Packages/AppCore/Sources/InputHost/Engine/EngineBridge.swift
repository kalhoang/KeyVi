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
    /// The PLT-R310 step 5 recogniser the pipeline builds from the hotkey bindings of each settings generation.
    /// Production uses `HotkeyRecognizer` (the default); test factories may name a reference recogniser.
    associatedtype Hotkeys: HotkeyRecognizing = HotkeyRecognizer
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

/// Eight prebuilt engines: appContext x englishRestore x macros (ENG-R850, `features`, ENG-R1107). Lookup is an
/// array index, so the tap never hashes or allocates to find an engine.
public struct EngineCatalog: Sendable {
    private let slots: [VietnameseEngine.Engine]

    /// Missing variants fall back to the default variant's engine (or a neutral engine for an empty catalog).
    public init(engines: [EngineVariant: VietnameseEngine.Engine]) {
        let fallback =
            engines[.default] ?? engines.values.first
            ?? VietnameseEngine.Engine(configuration: EngineConfiguration(), resources: .empty)
        slots = EngineVariant.catalogOrder.map { engines[$0] ?? fallback }
    }

    public func engine(for variant: EngineVariant) -> VietnameseEngine.Engine { slots[variant.catalogIndex] }
}

public enum MacroTableBuildIssue: Sendable, Hashable {
    case rejected(macroID: String, reason: MacroTable.ValidationError)
}

/// Pure mapping from settings to engine values. Runs on the utility queue when settings change.
public enum EngineBridge {
    /// D1, D2, D4, D5, D6 plus the variant.
    public static func configuration(for settings: EffectiveSettings, variant: EngineVariant) -> EngineConfiguration {
        EngineSettingsMapping.configuration(for: settings, variant: variant)
    }

    /// Enabled macros only; invalid entries are skipped and reported (the editor prevents them, PRD-R29).
    public static func macroTable(from macros: [StoredMacro]) -> (MacroTable, [MacroTableBuildIssue]) {
        MacroTableBuilder.build(from: macros) { try MacroTable($0) }
    }

    /// Loads bundled lexicons once (ENG-R1231: at most 50 ms) and attaches user lists and macros.
    public static func resources(
        settings: EffectiveSettings, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources {
        var resources = try bundledLoader()
        resources.userKeepRaw = WordSet(settings.keepAsTyped)
        resources.userKeepVietnamese = WordSet(settings.keepVietnamese)
        resources.macros = macros
        return resources
    }

    public static func catalog(settings: EffectiveSettings, resources: Resources) -> EngineCatalog {
        EngineSettingsMapping.catalog(settings: settings, resources: resources)
    }
}
