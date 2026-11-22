// SPDX-License-Identifier: MPL-2.0

import Foundation
import VietnameseEngine
import VietnameseEngineData
import VietnameseEngineTesting

/// The event streams of ENG-T40: the prose corpus of 13.4 and the generated Vietnamese corpus typed by
/// three simulated typists in both methods, and a fuzz stream. Everything is generated from fixed inputs
/// and seeds, so every run replays the same events.
struct Workload {
    let name: String
    let engine: Engine
    let events: [EngineEvent]
    /// The events whose latency a budget of their own bounds (the committing spaces of the `correction` workload,
    /// ENG-R1122); empty for the ENG-T40 workloads.
    var commits: [Int] = []
}

enum Workloads {
    /// The bundled word lists (spec 8.2, `Resources.bundled`) and a macro table of 10,000 random entries
    /// (ENG-R1105: tables of that size must stay within ENG-R1230).
    static func resources() throws -> Resources {
        let macros = try MacroTable(RandomMacroTable.entries(count: 10_000, seed: 0xBE7C_0001))
        return try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]), macros: macros)
    }

    /// `data/corpus/prose-vi.txt` of the repository this benchmark was built from (ENG-T20, 13.4).
    static var defaultProseCorpus: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EngineBenchmark
            .deletingLastPathComponent()  // Benchmarks
            .deletingLastPathComponent()  // VietnameseEngine
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repository
            .appendingPathComponent("data/corpus/prose-vi.txt")
    }

    /// The bundled English lexicon (`english.txt` of `VietnameseEngineData`) of the source tree this benchmark was
    /// built from: the words the candidates of ENG-T55 are typos of.
    static var defaultEnglishList: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EngineBenchmark
            .deletingLastPathComponent()  // Benchmarks
            .deletingLastPathComponent()  // VietnameseEngine
            .appendingPathComponent("Sources/VietnameseEngineData/Resources/english.txt")
    }

    /// ENG-T55, ENG-R1122: `count` typos of lexicon words of 5 to 24 letters and `adversarial` 24-letter tokens
    /// (`CorrectionCandidates`), each typed after the previous one's space and committed by a space, with the typo
    /// correction on whatever `--typo-correction` says. `commits` holds the committing spaces, the events the budget
    /// of 50 µs at p99 and 200 µs in the worst case bounds. Empty when the lexicon file is missing.
    static func correctionCandidates(resources: Resources, count: Int, adversarial: Int, seed: UInt64) throws
        -> Workload
    {
        let url = defaultEnglishList
        let lexicon =
            FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("#") } : []
        let tokens =
            CorrectionCandidates.typos(
                of: lexicon, neighbours: resources.correction.keyboardNeighbours, count: count, seed: seed)
            + CorrectionCandidates.adversarial(lexicon: lexicon, count: adversarial, seed: seed &+ 1)
        let (events, commits) = CorrectionCandidates.events(tokens)
        return Workload(
            name: "correction",
            engine: Engine(configuration: EngineConfiguration(typoCorrection: true), resources: resources),
            events: events, commits: commits)
    }

    /// The paragraphs of the prose corpus as words, at most `limit` words (0: all); nil when the file is
    /// missing.
    static func proseParagraphs(_ url: URL, limit: Int) throws -> [[String]]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var paragraphs: [[String]] = []
        var count = 0
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            var words = line.split(separator: " ").map(String.init)
            if limit > 0 { words = Array(words.prefix(limit - count)) }
            if words.isEmpty { break }
            paragraphs.append(words)
            count += words.count
        }
        return paragraphs
    }

    /// ENG-T40: the prose corpus typed by the three typists of ENG-T20 (`ProseCorpusCheck`: O2, O1, O3),
    /// one pass each, in Telex and VNI, words separated by a space and paragraphs by a Return.
    static func prose(resources: Resources, paragraphs: [[String]], typoCorrection: Bool) -> [Workload] {
        CorpusMethod.allCases.map { method in
            var events: [EngineEvent] = []
            for order in ProseCorpusCheck.typists {
                for words in paragraphs {
                    for (index, word) in words.enumerated() {
                        if index > 0 { events.append(.key(KeyInput(" "))) }
                        for key in ProseCorpusCheck.keys(for: word, method: method, order: order) {
                            events.append(.key(KeyInput(key)))
                        }
                    }
                    events.append(.key(KeyInput("\n")))
                }
            }
            return Workload(
                name: "prose-\(method.rawValue)",
                engine: Engine(
                    configuration: EngineConfiguration(
                        inputMethod: method.inputMethod, typoCorrection: typoCorrection),
                    resources: resources),
                events: events)
        }
    }

    /// The three typists over every Tier A toned syllable, in Telex and VNI, traditional style: O1
    /// (canonical, tone key last), O2 (tone right after the vowel group) and O3 (letters first, then
    /// modifiers and tone after the coda, the "free order" typist). Syllables are separated as in prose:
    /// mostly a space, sometimes `, ` or `. `, a Return now and then, and a mistyped letter corrected with
    /// Backspace every 17th syllable.
    static func typists(resources: Resources, typoCorrection: Bool) -> [Workload] {
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
                name: "typists-telex",
                engine: Engine(
                    configuration: EngineConfiguration(typoCorrection: typoCorrection), resources: resources),
                events: telex),
            Workload(
                name: "typists-vni",
                engine: Engine(
                    configuration: EngineConfiguration(inputMethod: .vni, typoCorrection: typoCorrection),
                    resources: resources),
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
    static func fuzz(resources: Resources, events count: Int, seed: UInt64, typoCorrection: Bool) -> [Workload] {
        let triggers = resources.macros.triggers
        return [
            EngineConfiguration(typoCorrection: typoCorrection),
            EngineConfiguration(inputMethod: .vni, typoCorrection: typoCorrection),
        ].enumerated().map {
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
            name: "long-\(length)",
            engine: Engine(configuration: EngineConfiguration(typoCorrection: false), resources: resources),
            events: events)
    }
}
