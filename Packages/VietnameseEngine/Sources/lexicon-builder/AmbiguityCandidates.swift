// SPDX-License-Identifier: MPL-2.0
//
// `lexicon-builder ambiguity-candidates` (ENG-R820): types every word of the English lexicon and of
// both tech lists through the engine (Telex, default options, traditional and modern tone style) and
// lists the words whose display is a Tier A syllable. Those are the candidate rows of the ambiguity
// table (ENG-R821).
//
// Extension (docs/decisions/0202): the spec lists only displays that are attested. A word whose raw keys
// are English and whose display is a valid but unattested Tier A syllable is restored by rule L8 before
// the table is read, which ENG-R870 cannot exclude unless the word is an `en` row; such words are listed
// too (`attested = no`). Words with a digit are also typed in VNI, the only method in which they can
// change (ENG-R874).

import Foundation
import VietnameseEngine

/// The input method whose typing produced a candidate's display.
enum CandidateMethod: String {
    case telex
    case vni
}

/// What the candidate generator needs from the engine. The real engine is used by default; tests
/// substitute a tiny table.
protocol CandidateTyper {
    /// Display after typing `raw` key by key (no commit).
    func display(typing raw: String, method: CandidateMethod, style: ToneStyle) -> String
    func validity(of display: String) -> Validity
}

struct EngineTyper: CandidateTyper {
    func display(typing raw: String, method: CandidateMethod, style: ToneStyle) -> String {
        let inputMethod: InputMethod = method == .telex ? .telex(TelexOptions()) : .vni
        let configuration = EngineConfiguration(inputMethod: inputMethod, toneStyle: style)
        var session = Session(engine: Engine(configuration: configuration, resources: .empty))
        for character in raw { _ = session.handle(.key(KeyInput(character))) }
        // A word that a boundary split into several tokens (a digit in Telex) has no single display.
        guard session.state.activeRawKeys == raw else { return raw }
        return session.state.activeDisplay
    }

    func validity(of display: String) -> Validity { Orthography.validity(of: display) }
}

/// Fake engine read from a TSV file: `raw  traditional  modern  validity(standard|extended|invalid)`
/// with an optional fifth column `telex` (default) or `vni`.
struct TableTyper: CandidateTyper {
    private var displays: [CandidateMethod: [String: (traditional: String, modern: String)]] = [:]
    private var validities: [String: Validity] = [:]

    init(_ url: URL) throws {
        for (number, line) in FileIO.dataLines(try FileIO.readUTF8(url)) {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 4 || fields.count == 5 else {
                throw BuilderError("fake engine line \(number): expected 4 or 5 fields")
            }
            guard let method = fields.count == 5 ? CandidateMethod(rawValue: fields[4]) : .telex else {
                throw BuilderError("fake engine line \(number): unknown method '\(fields[4])'")
            }
            guard let validity = Self.validity(named: fields[3]) else {
                throw BuilderError("fake engine line \(number): unknown validity '\(fields[3])'")
            }
            displays[method, default: [:]][fields[0]] = (fields[1], fields[2])
            validities[fields[1]] = validity
            validities[fields[2]] = validity
        }
    }

    private static func validity(named name: String) -> Validity? {
        switch name {
        case "standard": .standard
        case "extended": .extended
        case "invalid": .invalid
        default: nil
        }
    }

    func display(typing raw: String, method: CandidateMethod, style: ToneStyle) -> String {
        guard let entry = displays[method]?[raw] else { return raw }
        return style == .traditional ? entry.traditional : entry.modern
    }

    func validity(of display: String) -> Validity { validities[display] ?? .invalid }
}

/// Everything the generator reads, gathered once from the data directory (or built by a test).
struct CandidateInputs {
    /// English lexicon: word -> smallest SCOWL size level.
    var english: [String: Int]
    var techAlways: [String]
    var techCodeOnly: [String]
    /// The attested syllables of the built resources.
    var attested: Set<String>
    /// Occurrences of each token in the legal texts (frequency proxy).
    var counts: [String: Int]
    /// Current rows of `inputs/ambiguity.tsv`: raw -> `decision/status`.
    var rows: [String: String]
}

struct AmbiguityCandidate {
    let raw: String
    let method: CandidateMethod
    let traditional: String?
    let modern: String?
    /// Every display is in the attested list (ENG-R820). When false the display is a valid but unattested
    /// Tier A syllable: rule L8 restores the word whenever its raw keys are English.
    let attested: Bool
    /// The raw keys are English in the sense of spec 8.1 (English lexicon or tech-always list).
    let isEnglish: Bool
    let isTechAlways: Bool
    let source: String
    let rank: Int
    let corpusCount: Int
    let current: String

    /// The row `--merge` appends when the table has none (ENG-R821, docs/decisions/0202):
    /// - English raw keys with an unattested display: `en / proposed`, because rule L8 restores the word
    ///   before the table is read; a `vi` row would contradict the behaviour.
    /// - Tech-always words: `en / proposed`, the behaviour rule L11 gives them without a row.
    /// - Everything else: `vi / unreviewed`, which behaves as `vi` (never damage Vietnamese).
    var mergeRow: AmbiguityRow {
        let display = traditional ?? modern ?? ""
        let origin = "generated candidate (\(source)"
        if isEnglish && !attested {
            return AmbiguityRow(
                raw: raw, decision: .en, status: .proposed, display: display,
                note: "\(origin), display not attested): rule L8 restores it; proposed en to match "
                    + "(attest the syllable with a reason and set vi to keep it) "
                    + AmbiguityRow.GeneratedReason.unattested.rawValue)
        }
        if isTechAlways {
            return AmbiguityRow(
                raw: raw, decision: .en, status: .proposed, display: display,
                note: "\(origin)): proposed en so that the tech-always word stays as typed, as rule L11 "
                    + "does for tech-always words without a row " + AmbiguityRow.GeneratedReason.techAlways.rawValue)
        }
        return AmbiguityRow(
            raw: raw, decision: .vi, status: .unreviewed, display: display,
            note: "\(origin), corpus count \(corpusCount))")
    }

    var line: String {
        let merge = mergeRow
        return [
            raw, method.rawValue, traditional ?? "-", modern ?? "-", attested ? "yes" : "no", source,
            String(corpusCount), "\(merge.decision.rawValue)/\(merge.status.rawValue)", current,
        ].joined(separator: "\t")
    }

    static let header = "raw\tmethod\ttraditional\tmodern\tattested\tsource\tcorpus_count\tmerge_as\tcurrent_row"
}

enum AmbiguityCandidates {
    /// Rank used for words that are only in a tech list (sorted after every SCOWL level).
    static let techRank = 100

    static func generate(_ layout: Layout, typer: some CandidateTyper) throws -> [AmbiguityCandidate] {
        try candidates(loadInputs(layout), typer: typer)
    }

    static func loadInputs(_ layout: Layout) throws -> CandidateInputs {
        let attestedText = try FileIO.readUTF8(layout.resources.appendingPathComponent(ResourceName.attested))
        let rows = try AmbiguityRow.load(layout.inputs.appendingPathComponent("ambiguity.tsv")).map {
            ($0.raw, "\($0.decision.rawValue)/\($0.status.rawValue)")
        }
        return CandidateInputs(
            english: try EnglishLexicon.load(layout),
            techAlways: try TechList.load(layout.inputs.appendingPathComponent("tech-always.txt")),
            techCodeOnly: try TechList.load(layout.inputs.appendingPathComponent("tech-code-only.txt")),
            attested: Set(attestedText.split(separator: "\n").map(String.init)),
            counts: try corpusCounts(layout),
            rows: Dictionary(uniqueKeysWithValues: rows))
    }

    static func candidates(_ inputs: CandidateInputs, typer: some CandidateTyper) -> [AmbiguityCandidate] {
        var words: [String: (source: String, rank: Int)] = [:]
        for (word, level) in inputs.english { words[word] = ("scowl-\(level)", level) }
        for (list, entries) in [("tech-always", inputs.techAlways), ("tech-code-only", inputs.techCodeOnly)] {
            for word in entries where words[word] == nil { words[word] = (list, techRank) }
        }
        let techAlways = Set(inputs.techAlways)
        var result: [AmbiguityCandidate] = []
        for (raw, info) in words {
            guard let found = displays(of: raw, typer: typer) else { continue }
            let shown = [found.traditional, found.modern].compactMap { $0 }
            result.append(
                AmbiguityCandidate(
                    raw: raw, method: found.method, traditional: found.traditional, modern: found.modern,
                    attested: shown.allSatisfy(inputs.attested.contains),
                    isEnglish: inputs.english[raw] != nil || techAlways.contains(raw),
                    isTechAlways: techAlways.contains(raw), source: info.source, rank: info.rank,
                    corpusCount: shown.map { inputs.counts[$0] ?? 0 }.max() ?? 0, current: inputs.rows[raw] ?? "-"))
        }
        // Frequency proxy (ENG-R820): SCOWL size level first (10 = most common English words), then how
        // often the Vietnamese display occurs in the legal corpus, then the raw keys.
        return result.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.corpusCount != rhs.corpusCount { return lhs.corpusCount > rhs.corpusCount }
            return lhs.raw.utf8.lexicographicallyPrecedes(rhs.raw.utf8)
        }
    }

    /// The Tier A displays of `raw` in Telex (both styles), or in VNI when Telex leaves it unchanged and
    /// it has a digit; nil when neither style gives a Tier A syllable different from the raw keys.
    private static func displays(
        of raw: String, typer: some CandidateTyper
    ) -> (method: CandidateMethod, traditional: String?, modern: String?)? {
        var methods: [CandidateMethod] = [.telex]
        if raw.contains(where: \.isNumber) { methods.append(.vni) }
        for method in methods {
            func display(_ style: ToneStyle) -> String? {
                let display = typer.display(typing: raw, method: method, style: style)
                return display != raw && typer.validity(of: display) == .standard ? display : nil
            }
            let traditional = display(.traditional)
            let modern = display(.modern)
            if traditional != nil || modern != nil { return (method, traditional, modern) }
        }
        return nil
    }

    static func tsv(_ candidates: [AmbiguityCandidate]) -> String {
        joinedLines([AmbiguityCandidate.header] + candidates.map(\.line))
    }

    /// First line of the comment block that holds the generated `en` rows, always the last block of the table.
    static let generatedBlockMarker = "# [generated en rows]"

    static let generatedBlockHeader = [
        "\(generatedBlockMarker) Added by `ambiguity-candidates --merge` (docs/decisions/0202); not decided by Pa.",
        "# Each note ends with [generated:unattested] (English raw keys whose display is not attested: rule L8 restores",
        "# the word whatever the row says) or [generated:tech-always] (a tech-always word, kept as typed by rule L11).",
        "# `lexicon-builder build` fails when that reason no longer holds (the display was attested, the word left the",
        "# lexicon or the tech-always list): delete the row, then merge again or decide it by hand.",
    ]

    /// Adds the merge row of every candidate without a row (ENG-R821) and returns how many were added:
    /// `vi / unreviewed` rows before the generated block, generated `en` rows at its end (the block is
    /// created on first use), so that the rows Pa reviews are not mixed with generated decisions.
    static func merge(_ candidates: [AmbiguityCandidate], into url: URL) throws -> Int {
        let existing = Set(try AmbiguityRow.load(url).map(\.raw))
        let additions = candidates.filter { !existing.contains($0.raw) }.map(\.mergeRow)
        guard !additions.isEmpty else { return 0 }
        var lines = try FileIO.readUTF8(url).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let generated = additions.filter { $0.generatedReason != nil }.map(\.line)
        let reviewable = additions.filter { $0.generatedReason == nil }.map(\.line)
        if let marker = lines.firstIndex(where: { $0.hasPrefix(generatedBlockMarker) }) {
            lines.insert(contentsOf: reviewable, at: marker)
        } else {
            lines += reviewable
            if !generated.isEmpty { lines += generatedBlockHeader }
        }
        lines += generated
        try FileIO.write(joinedLines(lines), to: url)
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
