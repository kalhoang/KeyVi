// SPDX-License-Identifier: GPL-3.0-or-later
//
// How the engine is bridged (docs/decisions/0306-engine-bridge.md). The engine is a pure value type
// (`Engine.reduce`, 01-engine.md 12.2); the host keeps one `Session` on the tap thread and swaps engines only
// at hard boundaries (ENG-R1211), with one exception: a late focus change (PLT-R340) into a field whose variant
// differs only in `lookaheadRevision` continues a state that holds no committed token with the new engine
// (ENG-R1211 amendment of 19/11/2026). Engines are prebuilt off the hot path, one per variant.

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
    /// The engine of `variant` continuing `engine`'s state (ENG-R1211 amendment of 19/11/2026): only for a variant
    /// that differs from `engine`'s in `lookaheadRevision` alone, while the state holds no committed token, which
    /// is then the state the new engine would hold after the same keys. Tap thread, a late focus change (PLT-R340);
    /// MUST NOT allocate beyond copying prebuilt values.
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot, continuing engine: Engine) -> Engine
}

/// Production engine: a `VietnameseEngine.Session` over a prebuilt `Engine`.
public struct VietnameseCompositionEngine: CompositionEngine {
    public private(set) var session: Session
    public init(engine: VietnameseEngine.Engine) { session = Session(engine: engine) }
    /// `engine` continuing `state` (ENG-R1211 amendment of 19/11/2026, `makeEngine(for:settings:continuing:)`).
    public init(engine: VietnameseEngine.Engine, continuing state: EngineState) {
        session = Session(engine: engine, state: state)
    }
    public mutating func handle(_ event: EngineEvent) -> EngineOutput { session.handle(event) }
    public var activeDisplay: String { session.state.activeDisplay }
}

public struct VietnameseCompositionEngineFactory: CompositionEngineFactory, Sendable {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> VietnameseCompositionEngine {
        VietnameseCompositionEngine(engine: settings.engines.engine(for: variant))
    }

    public func makeEngine(
        for variant: EngineVariant, settings: TapSettingsSnapshot, continuing engine: VietnameseCompositionEngine
    ) -> VietnameseCompositionEngine {
        VietnameseCompositionEngine(engine: settings.engines.engine(for: variant), continuing: engine.session.state)
    }
}

/// Sixteen prebuilt engines: appContext x englishRestore x macros x lookaheadRevision (ENG-R850, `features`,
/// ENG-R1107, PLT-R357). Lookup is an array index, so the tap never hashes or allocates to find an engine.
public struct EngineCatalog: Sendable {
    private let slots: [VietnameseEngine.Engine]
    /// Identifies the engine-affecting settings the catalog was built from (PRD-R27, PLT-R340). The publisher
    /// keeps it when a settings change leaves the engines alone (hotkeys, UI language, update channel), so the
    /// tap rebuilds only the hotkeys and keeps the word being typed. `nil` means unknown: every new settings
    /// generation builds a fresh engine, the safe default.
    public let revision: UInt64?
    /// Identifies the learned collision memory the engines carry (ENG-R865). A catalog whose `revision` is the
    /// previous one and whose `memoryRevision` is new differs only by the memory: the tap swaps it in at the next
    /// hard boundary instead of resetting the word being typed (ENG-R1211).
    public let memoryRevision: UInt64

    /// Missing variants fall back to the default variant's engine (or a neutral engine without word lists for an empty
    /// catalog; it makes no typo correction, ENG-R1119).
    public init(engines: [EngineVariant: VietnameseEngine.Engine], revision: UInt64? = nil, memoryRevision: UInt64 = 0)
    {
        let fallback =
            engines[.default] ?? engines.values.first
            ?? VietnameseEngine.Engine(configuration: EngineConfiguration(typoCorrection: false), resources: .empty)
        slots = EngineVariant.catalogOrder.map { engines[$0] ?? fallback }
        self.revision = revision
        self.memoryRevision = memoryRevision
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

    /// Loads bundled lexicons once (ENG-R1231: at most 50 ms) and attaches the global user lists and macros.
    public static func resources(
        settings: EffectiveSettings, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources {
        try resources(
            wordLists: UserWordLists(keepAsTyped: settings.keepAsTyped, keepVietnamese: settings.keepVietnamese),
            macros: macros, bundledLoader: bundledLoader)
    }

    /// Attaches the focused app's user lists (global entries plus the words learned in that app, ENG-R862) and the
    /// macros. The engine gets word sets only, never the app (ENG-R851).
    public static func resources(
        wordLists: UserWordLists, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources {
        var resources = try bundledLoader()
        resources.userKeepRaw = WordSet(wordLists.keepAsTyped)
        resources.userKeepVietnamese = WordSet(wordLists.keepVietnamese)
        resources.macros = macros
        return resources
    }

    /// `revision` identifies the engine-affecting settings (see `EngineCatalog.revision`); the publisher bumps it
    /// only when the catalog's inputs change.
    public static func catalog(
        settings: EffectiveSettings, resources: Resources, revision: UInt64? = nil, memoryRevision: UInt64 = 0
    ) -> EngineCatalog {
        EngineSettingsMapping.catalog(
            settings: settings, resources: resources, revision: revision, memoryRevision: memoryRevision)
    }
}
