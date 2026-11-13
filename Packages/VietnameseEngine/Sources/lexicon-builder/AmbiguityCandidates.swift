// SPDX-License-Identifier: MPL-2.0
//
// `lexicon-builder ambiguity-candidates` (ENG-R820): types every word of the English lexicon and of
// both tech lists through the engine (Telex, default options, traditional and modern tone style) and
// lists the words whose display is an attested Tier A syllable. Those are the candidate rows of the
// ambiguity table (ENG-R821).

import Foundation
import VietnameseEngine

/// What the candidate generator needs from the engine. The real engine is used by default; tests
/// substitute a tiny table so that the plumbing is testable before the engine exists.
protocol CandidateTyper {
    /// Display after typing `raw` key by key (no commit).
    func display(typing raw: String, style: ToneStyle) -> String
    func validity(of display: String) -> Validity
}

struct EngineTyper: CandidateTyper {
    func display(typing raw: String, style: ToneStyle) -> String {
        let configuration = EngineConfiguration(inputMethod: .telex(TelexOptions()), toneStyle: style)
        var session = Session(engine: Engine(configuration: configuration, resources: .empty))
        for character in raw { _ = session.handle(.key(KeyInput(character))) }
        return session.state.activeDisplay
    }

    func validity(of display: String) -> Validity { Orthography.validity(of: display) }
}

/// Fake engine read from a TSV file: `raw  traditional  modern  validity(standard|extended|invalid)`.
struct TableTyper: CandidateTyper {
    private let displays: [String: (traditional: String, modern: String)]
    private let validities: [String: Validity]

    init(_ url: URL) throws {
        var displays: [String: (traditional: String, modern: String)] = [:]
        var validities: [String: Validity] = [:]
        for (number, line) in FileIO.dataLines(try FileIO.readUTF8(url)) {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 4 else { throw BuilderError("fake engine line \(number): expected 4 fields") }
            let validity: Validity
            switch fields[3] {
            case "standard": validity = .standard
            case "extended": validity = .extended
            case "invalid": validity = .invalid
            default: throw BuilderError("fake engine line \(number): unknown validity '\(fields[3])'")
            }
            displays[fields[0]] = (fields[1], fields[2])
            validities[fields[1]] = validity
            validities[fields[2]] = validity
        }
        self.displays = displays
        self.validities = validities
    }

    func display(typing raw: String, style: ToneStyle) -> String {
        guard let entry = displays[raw] else { return raw }
        return style == .traditional ? entry.traditional : entry.modern
    }

    func validity(of display: String) -> Validity { validities[display] ?? .invalid }
}

struct AmbiguityCandidate {
    let raw: String
    let traditional: String?
    let modern: String?
    let source: String
    let rank: Int
    let corpusCount: Int
    let current: String

    var line: String {
        "\(raw)\t\(traditional ?? "-")\t\(modern ?? "-")\t\(source)\t\(corpusCount)\t\(current)"
    }

    static let header = "raw\ttraditional\tmodern\tsource\tcorpus_count\tcurrent_row"
}

enum AmbiguityCandidates {
    /// Rank used for words that are only in a tech list (sorted after every SCOWL level).
    static let techRank = 100

    static func generate(_ layout: Layout, typer: some CandidateTyper) throws -> [AmbiguityCandidate] {
        let english = try EnglishLexicon.load(layout)
        var words: [String: (source: String, rank: Int)] = [:]
        for (word, level) in english { words[word] = ("scowl-\(level)", level) }
        for list in ["tech-always", "tech-code-only"] {
            for word in try TechList.load(layout.inputs.appendingPathComponent("\(list).txt")) where words[word] == nil {
                words[word] = (list, techRank)
            }
        }
        let attestedText = try FileIO.readUTF8(layout.resources.appendingPathComponent(ResourceName.attested))
        let attested = Set(attestedText.split(separator: "\n").map(String.init))
        let counts = try corpusCounts(layout)
        let rows = Dictionary(
            uniqueKeysWithValues: try AmbiguityRow.load(layout.inputs.appendingPathComponent("ambiguity.tsv")).map {
                ($0.raw, "\($0.decision.rawValue)/\($0.status.rawValue)")
            })

        func candidateDisplay(_ raw: String, _ style: ToneStyle) -> String? {
            let display = typer.display(typing: raw, style: style)
            guard display != raw, attested.contains(display), typer.validity(of: display) == .standard else { return nil }
            return display
        }

        var result: [AmbiguityCandidate] = []
        for (raw, info) in words {
            let traditional = candidateDisplay(raw, .traditional)
            let modern = candidateDisplay(raw, .modern)
            guard traditional != nil || modern != nil else { continue }
            let count = max(traditional.map { counts[$0] ?? 0 } ?? 0, modern.map { counts[$0] ?? 0 } ?? 0)
            result.append(
                AmbiguityCandidate(
                    raw: raw, traditional: traditional, modern: modern, source: info.source, rank: info.rank,
                    corpusCount: count, current: rows[raw] ?? "-"))
        }
        // Frequency proxy (ENG-R820): SCOWL size level first (10 = most common English words), then how
        // often the Vietnamese display occurs in the legal corpus, then the raw keys.
        return result.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.corpusCount != rhs.corpusCount { return lhs.corpusCount > rhs.corpusCount }
            return lhs.raw.utf8.lexicographicallyPrecedes(rhs.raw.utf8)
        }
    }

    static func tsv(_ candidates: [AmbiguityCandidate]) -> String {
        joinedLines([AmbiguityCandidate.header] + candidates.map(\.line))
    }

    /// Appends every candidate without a row as `vi / unreviewed` (ENG-R821: unreviewed rows behave as vi).
    static func merge(_ candidates: [AmbiguityCandidate], into url: URL) throws -> Int {
        let existing = Set(try AmbiguityRow.load(url).map(\.raw))
        let additions = candidates.filter { !existing.contains($0.raw) }.map { candidate in
            AmbiguityRow(
                raw: candidate.raw, decision: .vi, status: .unreviewed,
                display: candidate.traditional ?? candidate.modern ?? "",
                note: "generated candidate (\(candidate.source), corpus count \(candidate.corpusCount))")
        }
        guard !additions.isEmpty else { return 0 }
        var text = try FileIO.readUTF8(url)
        if !text.hasSuffix("\n") { text += "\n" }
        text += joinedLines(additions.map(\.line))
        try FileIO.write(text, to: url)
        return additions.count
    }

    private static func corpusCounts(_ layout: Layout) throws -> [String: Int] {
        let url = layout.derived.appendingPathComponent(ResourceName.attestedCandidates)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var counts: [String: Int] = [:]
        for line in try FileIO.readUTF8(url).split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t")
            if fields.count == 2, let count = Int(fields[1]) { counts[String(fields[0])] = count }
        }
        return counts
    }
}
