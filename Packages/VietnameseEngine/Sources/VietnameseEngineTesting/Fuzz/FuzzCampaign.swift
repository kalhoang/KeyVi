// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// One configuration of the fuzz campaign: an engine configuration (method, options, tone style, auto
/// restore, app context, history limit), with or without the random macro table, with the 13.9 fixture
/// resources or empty ones.
public struct FuzzCombination: Sendable, Hashable, CustomStringConvertible {
    /// The engine configuration.
    public let configuration: EngineConfiguration
    /// Whether the random macro table is used.
    public let withMacros: Bool
    /// The 13.9 fixture resources when true, empty resources otherwise.
    public let fixtureResources: Bool

    /// A combination.
    public init(configuration: EngineConfiguration, withMacros: Bool, fixtureResources: Bool = true) {
        self.configuration = configuration
        self.withMacros = withMacros
        self.fixtureResources = fixtureResources
    }

    /// Every option combination of 4.8 and 12.2 (QA-R7 "both methods, all option combinations"): Telex with
    /// standalone `w` on and off and bracket keys on and off, and VNI; each with both tone styles, auto
    /// restore on and off, and both app contexts; each with and without the macro table. History limits
    /// (16, 1, 2, 5) and empty resources (one combination in four) are spread over the set. 80
    /// combinations.
    public static let all: [FuzzCombination] = {
        var methods: [InputMethod] = []
        for standaloneW in [true, false] {
            for bracketKeys in [false, true] {
                methods.append(.telex(TelexOptions(standaloneW: standaloneW, bracketKeys: bracketKeys)))
            }
        }
        methods.append(.vni)
        let historyLimits = [16, 1, 2, 5]
        var result: [FuzzCombination] = []
        for method in methods {
            for style in [ToneStyle.traditional, .modern] {
                for autoRestore in [true, false] {
                    for context in [AppContext.general, .code] {
                        for withMacros in [false, true] {
                            let index = result.count
                            let configuration = EngineConfiguration(
                                inputMethod: method, toneStyle: style, autoRestore: autoRestore, appContext: context,
                                historyLimit: historyLimits[index % historyLimits.count])
                            result.append(
                                FuzzCombination(
                                    configuration: configuration, withMacros: withMacros,
                                    fixtureResources: index % 4 != 3))
                        }
                    }
                }
            }
        }
        return result
    }()

    /// The resources of the combination.
    public func resources(macros: MacroTable) -> Resources {
        let table = withMacros ? macros : .empty
        guard fixtureResources else {
            return Resources(
                english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
                attestedSyllables: WordSet([]), ambiguity: [:], userKeepRaw: WordSet([]),
                userKeepVietnamese: WordSet([]), macros: table)
        }
        return SpecFixtures.commitResources(userKeepRaw: ["tets"], userKeepVietnamese: ["test"], macros: table)
    }

    /// A compact label such as `telex,traditional,restore,general,h16,macros,fixtures`.
    public var description: String {
        let method: String
        switch configuration.inputMethod {
        case .telex(let options):
            method = "telex\(options.standaloneW ? "" : "-noW")\(options.bracketKeys ? "-brackets" : "")"
        case .vni: method = "vni"
        }
        return [
            method, configuration.toneStyle == .modern ? "modern" : "traditional",
            configuration.autoRestore ? "restore" : "noRestore", configuration.appContext == .code ? "code" : "general",
            "h\(configuration.historyLimit)", withMacros ? "macros" : "noMacros",
            fixtureResources ? "fixtures" : "empty",
        ].joined(separator: ",")
    }
}

/// Runs seeded fuzz streams through an `InvariantChecker` (spec 13.6, QA-R7, QA-R8).
public enum FuzzCampaign {
    /// The default number of events of `swift test` (QA-R8: at least 1,000,000 per pull request).
    public static let defaultEventCount = 1_000_000

    /// Runs `events` events of `combination` from `seed`. Throws the first `FuzzViolation`.
    public static func run(
        _ combination: FuzzCombination, seed: UInt64, events: Int, macros: MacroTable,
        options: InvariantChecker.Options = InvariantChecker.Options(), maximumBurst: Int = 4_096
    ) throws -> FuzzStatistics {
        let engine = Engine(configuration: combination.configuration, resources: combination.resources(macros: macros))
        let triggers = combination.withMacros ? macros.triggers : []
        var source = FuzzEventSource(
            seed: seed, configuration: combination.configuration, triggers: triggers, maximumBurst: maximumBurst)
        var checker = InvariantChecker(engine: engine, options: options, probeSeed: seed ^ 0xE5CA_9E00)
        for _ in 0..<events { try checker.send(source.next()) }
        try checker.finish()
        return checker.statistics
    }

    /// Long tokens (REG-02, ENG-R640, ENG-R641): one token of `length` token keys of the method (a single
    /// repeated key when `singleKey` is set), with or without a few Backspace and restore toggles inside,
    /// then the toggle and a boundary. Checks every invariant along the way and that the toggle shows the
    /// raw keys exactly, whatever the length.
    public static func longToken(
        configuration: EngineConfiguration, length: Int, seed: UInt64, singleKey: Bool, edits: Bool,
        options: InvariantChecker.Options = InvariantChecker.Options()
    ) throws -> FuzzStatistics {
        let engine = Engine(configuration: configuration, resources: SpecFixtures.commitResources())
        var source = FuzzEventSource(seed: seed, configuration: configuration, maximumBurst: length)
        var checker = InvariantChecker(engine: engine, options: options, probeSeed: seed)
        let repeated = source.tokenKey()
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<length {
            if edits, generator.chance(1, in: 500) {
                try checker.send(generator.chance(1, in: 2) ? .backspace : .restoreToggle)
            } else {
                try checker.send(.key(KeyInput(singleKey ? repeated : source.tokenKey())))
            }
        }
        if let token = checker.session.state.active, !checker.session.state.previousEventWasRestoreToggle {
            let raw = token.rawText
            try checker.send(.restoreToggle)
            if checker.session.state.activeDisplay != raw, token.display != raw {
                throw FuzzViolation(
                    invariant: "ENG-T32", detail: "toggle on a \(length)-key token is not exact",
                    eventIndex: checker.statistics.events, recentEvents: [])
            }
        }
        try checker.send(.key(KeyInput(" ")))
        try checker.finish()
        return checker.statistics
    }
}

extension MacroTable {
    /// The triggers of the table, in entry order (for fuzz streams that type them).
    public var triggers: [String] { entries.map(\.trigger) }
}
