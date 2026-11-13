// SPDX-License-Identifier: GPL-3.0-or-later
//
// Engine factory wrapper for the PLT-R305 pipeline allocation test: every engine call runs with
// `AllocationCounter` paused, so the test measures the pipeline, not the engine (ENG-R1230 covers that).

public import InputHost
public import VietnameseEngine

/// Wraps a factory so every engine call runs with allocation counting paused: the PLT-R305 test measures the
/// pipeline, not the engine (whose own budget is ENG-R1230).
public struct AllocationExcludingFactory<Base: CompositionEngineFactory>: CompositionEngineFactory {
    public typealias Hotkeys = Base.Hotkeys

    public struct Engine: CompositionEngine {
        var base: Base.Engine
        public mutating func handle(_ event: EngineEvent) -> EngineOutput {
            AllocationCounter.pause()
            defer { AllocationCounter.resume() }
            return base.handle(event)
        }
        public var activeDisplay: String { base.activeDisplay }
    }

    private let base: Base
    public init(_ base: Base) { self.base = base }

    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> Engine {
        AllocationCounter.pause()
        defer { AllocationCounter.resume() }
        return Engine(base: base.makeEngine(for: variant, settings: settings))
    }
}
