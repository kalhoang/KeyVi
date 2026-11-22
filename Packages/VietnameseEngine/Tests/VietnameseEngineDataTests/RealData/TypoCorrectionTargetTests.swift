// SPDX-License-Identifier: MPL-2.0
//
// ENG-T52 and ENG-T53 with the bundled data (spec/01-engine.md 11A.5, the targets of ENG-R1124; plan of 19/11/2026,
// Task 21): injected typos of lexicon words are corrected to their source at the rates of ENG-R1124 and rarely to
// another word; rare dictionary words outside the lexicon and the guard list are rarely corrected. Every test prints
// its counts; the figures and seeds are recorded in TRACEABILITY.md.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T52, ENG-T53: injected typos and rare words, with the bundled data")
struct TypoCorrectionTargetTests {
    /// The seed of ENG-T52; each kind draws from `seed + its index in TypoKind.allCases`.
    static let seed: UInt64 = 18_112_026
    static let wordsPerKind = 6_000

    /// ENG-R1124: the share of typos corrected to their source, per kind.
    static let toTheSource: [TypoKind: Double] = [
        .transposition: 0.80, .omission: 0.50, .insertion: 0.70, .doubling: 0.90, .neighbour: 0.80,
    ]
    /// ENG-R1124: at most this share of typos corrected to another word, per kind.
    static let toAnotherWord = 0.015

    static let configuration = EngineConfiguration(typoCorrection: true)

    /// 6,000 words of the lexicon of five letters or more per kind, one edit each, typed after a space and committed
    /// by a space: the words corrected to the source, to another word and left alone are counted.
    @Test("ENG-T52: injected typos are corrected to their source", arguments: TypoKind.allCases)
    func injectedTyposAreCorrectedToTheirSource_ENGT52(_ kind: TypoKind) throws {
        let resources = try RealData.resources()
        let lexicon = try String(
            contentsOf: TestPaths.committedResources.appendingPathComponent("english.txt"), encoding: .utf8
        ).split(separator: "\n").map(String.init).filter { $0.utf8.count >= 5 }
        let kindSeed = Self.seed &+ UInt64(TypoKind.allCases.firstIndex(of: kind) ?? 0)
        var generator = TypoGenerator(seed: kindSeed, neighbours: resources.correction.keyboardNeighbours)
        var sources: [String: String] = [:]
        var typos: [String] = []
        for word in generator.sample(lexicon, count: Self.wordsPerKind) {
            guard let typo = generator.typo(of: word, kind: kind), typo != word else { continue }
            typos.append(typo)
            sources[typo] = sources[typo] ?? word
        }
        let outcomes = CorrectionCheck.outcomes(
            of: typos, resources: resources, configuration: Self.configuration, after: " ")
        let corrected = outcomes.filter { if case .corrected? = $0.decision { true } else { false } }
        let toSource = corrected.filter { $0.committed == sources[$0.word] }
        let toOther = corrected.filter { $0.committed != sources[$0.word] }
        // Informational: a Telex escape by doubling (`upsstarting`, kept by L4) already shows the source; such a
        // token is not a candidate (ENG-R1110 (b)) and is not counted as corrected.
        let shownByComposition = outcomes.filter {
            $0.decision.map(Self.isCorrection) != true && $0.committed == sources[$0.word]
        }
        let total = Double(typos.count)
        print(
            "[ENG-T52] \(kind), seed \(kindSeed): \(typos.count) typos; to the source \(toSource.count) ("
                + String(format: "%.2f %%", Double(toSource.count) / total * 100)
                + "), to another word \(toOther.count) ("
                + String(format: "%.2f %%", Double(toOther.count) / total * 100) + "), untouched "
                + "\(typos.count - corrected.count) (\(shownByComposition.count) of them shown as the source by the "
                + "composition, a Telex escape); to another word:\n"
                + RealData.listing(toOther.prefix(40).map { "\($0) from \(sources[$0.word] ?? "")" }))
        #expect(typos.count >= Self.wordsPerKind * 9 / 10)
        #expect(Double(toSource.count) / total >= Self.toTheSource[kind] ?? 1, "\(kind)")
        #expect(Double(toOther.count) / total <= Self.toAnotherWord, "\(kind)")
    }

    static func isCorrection(_ decision: CommitDecision) -> Bool {
        if case .corrected = decision { true } else { false }
    }

    static let dictionary = URL(fileURLWithPath: "/usr/share/dict/words")
    static let rareShards = 4

    /// Every word of `/usr/share/dict/words` with five or more ASCII letters, lowercased, that is neither in the
    /// lexicon nor in the guard list, typed lowercase after a space: at most 3.5 % corrected over the four shards
    /// together (each shard asserts its own share, so that a shard of the list cannot hide in the total).
    @Test(
        "ENG-T53: rare words are rarely corrected",
        .enabled(if: FileManager.default.fileExists(atPath: dictionary.path)),
        arguments: Array(0..<rareShards))
    func rareWordsAreRarelyCorrected_ENGT53(_ shard: Int) throws {
        let resources = try RealData.resources()
        let words = try Self.rareWords(resources)
        let mine = words.enumerated().filter { $0.offset % Self.rareShards == shard }.map(\.element)
        let corrected = CorrectionCheck.corrections(
            of: mine, resources: resources, configuration: Self.configuration, after: " ")
        let share = Double(corrected.count) / Double(max(1, mine.count))
        print(
            "[ENG-T53] shard \(shard) of \(Self.rareShards): \(words.count) rare words in all, \(mine.count) here, "
                + "\(corrected.count) corrected (" + String(format: "%.2f %%", share * 100) + "):\n"
                + RealData.listing(corrected.map { "\($0.word) -> \($0.committed)" }))
        #expect(words.count > 100_000)
        #expect(share <= 0.035)
    }

    /// The denominator of ENG-T53: the dictionary's words of five or more ASCII letters, lowercased, outside the
    /// lexicon and the guard list (the tech lists stay in it, ENG-R1110 (c) keeps them), unique and sorted.
    static func rareWords(_ resources: Resources) throws -> [String] {
        let text = try String(contentsOf: dictionary, encoding: .utf8)
        var words = Set<String>()
        for line in text.split(separator: "\n") {
            let word = line.lowercased()
            guard word.utf8.count >= 5, word.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { continue }
            if !resources.english.contains(word), !resources.correction.guardList.mayContain(word) {
                words.insert(word)
            }
        }
        return words.sorted()
    }
}
