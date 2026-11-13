// SPDX-License-Identifier: MPL-2.0

import VietnameseEngine
import VietnameseEngineTesting

/// The event streams of ENG-T40: the generated Vietnamese corpus typed by three simulated typists in
/// both methods, and a fuzz stream. Everything is generated from fixed seeds, so every run replays the
/// same events.
struct Workload {
    let name: String
    let engine: Engine
    let events: [EngineEvent]
}

enum Workloads {
    /// The 13.9 fixture word lists and a macro table of 10,000 random entries (ENG-R1105: tables of that
    /// size must stay within ENG-R1230).
    static func resources() throws -> Resources {
        let macros = try MacroTable(RandomMacroTable.entries(count: 10_000, seed: 0xBE7C_0001))
        return SpecFixtures.commitResources(macros: macros)
    }

    /// The three typists of ENG-R873 and ENG-T20 over every Tier A toned syllable, in Telex and VNI,
    /// traditional style: O1 (canonical, tone key last), O2 (tone right after the vowel group) and O3
    /// (letters first, then modifiers and tone after the coda, the "free order" typist). The generated
    /// corpus stands in for the prose corpus of 13.4 until the data track supplies one. Syllables are
    /// separated as in prose: mostly a space, sometimes `, ` or `. `, a Return now and then, and a
    /// mistyped letter corrected with Backspace every 17th syllable.
    static func typists(resources: Resources) -> [Workload] {
        var telex: [EngineEvent] = []
        var vni: [EngineEvent] = []
        var counter = 0
        GeneratedCorpus.forEachOrderCase { generated in
            guard generated.style == .traditional, case .order(let order) = generated.kind,
                order == .o1 || order == .o2 || order == .o3
            else { return }
            counter += 1
            var events = generated.events
            if counter % 17 == 0 { events += [.key(KeyInput("q")), .backspace] }
            events += separator(counter)
            if generated.method == .telex { telex += events } else { vni += events }
        }
        return [
            Workload(
                name: "typists-telex", engine: Engine(configuration: EngineConfiguration(), resources: resources),
                events: telex),
            Workload(
                name: "typists-vni",
                engine: Engine(configuration: EngineConfiguration(inputMethod: .vni), resources: resources),
                events: vni),
        ]
    }

    private static func separator(_ counter: Int) -> [EngineEvent] {
        if counter % 50 == 0 { return [.key(KeyInput("\n"))] }
        if counter % 13 == 0 { return [.key(KeyInput(".")), .key(KeyInput(" "))] }
        if counter % 7 == 0 { return [.key(KeyInput(",")), .key(KeyInput(" "))] }
        return [.key(KeyInput(" "))]
    }

    /// The fuzz stream of 13.6 (`FuzzEventSource`: full alphabet, words, macro triggers, Backspace runs,
    /// toggles, resets and bursts of up to 4,096 keys), Telex defaults and VNI alternating in blocks.
    static func fuzz(resources: Resources, events count: Int, seed: UInt64) -> [Workload] {
        let triggers = resources.macros.triggers
        return [EngineConfiguration(), EngineConfiguration(inputMethod: .vni)].enumerated().map {
            index, configuration in
            var source = FuzzEventSource(
                seed: seed &+ UInt64(index), configuration: configuration, triggers: triggers, maximumBurst: 4_096)
            return Workload(
                name: index == 0 ? "fuzz-telex" : "fuzz-vni",
                engine: Engine(configuration: configuration, resources: resources), events: source.events(count / 2))
        }
    }

    /// Single long tokens, for the informational long-token figures: `length` keys then `ending`.
    static func longToken(length: Int, keys: String, ending: EngineEvent, resources: Resources) -> Workload {
        let pattern = Array(keys)
        var events: [EngineEvent] = []
        events.reserveCapacity(length + 1)
        for index in 0..<length { events.append(.key(KeyInput(pattern[index % pattern.count]))) }
        events.append(ending)
        return Workload(
            name: "long-\(length)", engine: Engine(configuration: EngineConfiguration(), resources: resources),
            events: events)
    }
}
