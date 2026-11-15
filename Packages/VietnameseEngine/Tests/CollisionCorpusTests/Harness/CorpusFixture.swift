// SPDX-License-Identifier: MPL-2.0
//
// The W11 collision fixtures (spec/01-engine.md 13.11, QA-R68): one sentence per line, tab-separated columns
// id, group, half, keys, expected, revised, tokens (format, provenance and update rules in Fixtures/README.txt).

import Foundation
import VietnameseEngine

/// The label of one word of a fixture sentence.
enum WordLabel: Hashable {
    /// A word that is not scored as a collision (the collision rules must leave it as the engine without them
    /// commits it).
    case plain
    /// A collision token: the intended language, the corpus category and the position tags.
    case collision(intended: Language, category: String, positions: [String])
    /// A Vietnamese word whose keys are a collision outside the English lexicon (`cos` for `có`): no rule
    /// changes it, but a learned vote could (ENG-R863).
    case hidden
}

/// One word of a fixture sentence: what the writer meant and its label.
struct LabelledWord: Hashable {
    let intended: String
    let label: WordLabel
}

/// One line of a fixture file.
struct CorpusSentence: Hashable {
    let id: String
    /// `mixed`, `pure-vi` or `pure-en` for the corpus, `set` for the adversarial sets.
    let group: String
    /// `A` or `B`: the fixed split of the held-out memory test (ENG-R877); `-` for the sets.
    let half: String
    /// The keys typed, `{RET}` for Return (HostInput.parse).
    let keys: String
    /// The field after the replay with the engine the fixture was frozen with, `{RET}` for a line break.
    let expected: String
    /// Token index -> revision reason name (ENG-R828) in the frozen replay.
    let revised: [Int: String]
    let words: [LabelledWord]
}

/// A fixture file of the target's resources.
enum CorpusFixture: String, CaseIterable, CustomStringConvertible {
    case toneLast = "corpus-tone-last"
    case toneAfterVowel = "corpus-tone-after-vowel"
    case adversarial = "set-adversarial"
    case stress = "set-stress"
    case heldOut = "set-held-out"

    var description: String { rawValue }

    /// The three adversarial sets of 13.11.
    static let sets: [CorpusFixture] = [.adversarial, .stress, .heldOut]

    var url: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "tsv", subdirectory: "Fixtures")
            else { throw FixtureFormatError(file: rawValue, line: 0, reason: "missing from the test bundle") }
            return url
        }
    }

    /// The header lines (comments) and the parsed sentences.
    func load() throws -> (header: [String], sentences: [CorpusSentence]) {
        try Self.parse(String(contentsOf: url, encoding: .utf8), file: rawValue)
    }

    static func parse(_ text: String, file: String) throws -> (header: [String], sentences: [CorpusSentence]) {
        var header: [String] = []
        var sentences: [CorpusSentence] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("#") {
                header.append(String(line))
            } else if !line.isEmpty {
                sentences.append(try sentence(String(line), file: file, line: index + 1))
            }
        }
        guard Set(sentences.map(\.id)).count == sentences.count else {
            throw FixtureFormatError(file: file, line: 0, reason: "duplicate sentence id")
        }
        return (header, sentences)
    }

    static func sentence(_ text: String, file: String, line number: Int) throws -> CorpusSentence {
        func fail(_ reason: String) -> FixtureFormatError {
            FixtureFormatError(file: file, line: number, reason: reason)
        }
        let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7 else { throw fail("\(fields.count) columns, expected 7") }
        guard ["A", "B", "-"].contains(fields[2]) else { throw fail("half must be A, B or -") }
        guard !fields[3].isEmpty, !fields[6].isEmpty else { throw fail("keys and tokens must not be empty") }
        let words = try fields[6].split(separator: " ", omittingEmptySubsequences: false).map {
            try labelledWord(String($0), fail: fail)
        }
        return CorpusSentence(
            id: fields[0], group: fields[1], half: fields[2], keys: fields[3], expected: fields[4],
            revised: try revisions(fields[5], fail: fail), words: words)
    }

    static func labelledWord(_ item: String, fail: (String) -> FixtureFormatError) throws -> LabelledWord {
        let parts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let word = parts.first, !word.isEmpty, word.allSatisfy(\.isLetter) else {
            throw fail("word \(item) is not a run of letters")
        }
        switch parts.count {
        case 1:
            return LabelledWord(intended: word, label: .plain)
        case 2 where parts[1] == "H":
            return LabelledWord(intended: word, label: .hidden)
        case 4 where parts[1] == "E" || parts[1] == "V":
            let positions = parts[3] == "-" ? [] : parts[3].split(separator: ",").map(String.init)
            return LabelledWord(
                intended: word,
                label: .collision(
                    intended: parts[1] == "E" ? .english : .vietnamese, category: parts[2], positions: positions))
        default:
            throw fail("token \(item): expected word, word/H or word/E|V/category/positions")
        }
    }

    static func revisions(_ field: String, fail: (String) -> FixtureFormatError) throws -> [Int: String] {
        guard field != "-" else { return [:] }
        var result: [Int: String] = [:]
        for item in field.split(separator: ",") {
            let pair = item.split(separator: ":").map(String.init)
            guard pair.count == 2, let index = Int(pair[0]), RevisionName.all.contains(pair[1]) else {
                throw fail("revision \(item): expected index:reason")
            }
            result[index] = pair[1]
        }
        return result
    }
}

/// The names the fixtures use for `RevisionReason` (ENG-R828).
enum RevisionName {
    static let all: Set<String> = ["phrase", "particleTail", "nextEnglish", "nextVietnamese"]

    static func of(_ reason: RevisionReason) -> String {
        switch reason {
        case .phrase: "phrase"
        case .particleTail: "particleTail"
        case .nextEnglish: "nextEnglish"
        case .nextVietnamese: "nextVietnamese"
        }
    }
}

/// A malformed fixture line.
struct FixtureFormatError: Error, CustomStringConvertible {
    let file: String
    let line: Int
    let reason: String

    var description: String { "\(file).tsv:\(line): \(reason)" }
}
