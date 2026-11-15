// SPDX-License-Identifier: MPL-2.0
//
// `lexicon-builder build`: pinned inputs -> bundled resources (spec/01-engine.md 8.2, ENG-R810).
// Every output is a pure function of the pinned inputs and of `Orthography.validity`: no dates, no
// host paths, no locale-dependent ordering, so two builds produce identical bytes.

import Foundation
import VietnameseEngine

struct BuildOutput {
    /// File name -> contents, for the resource directory.
    var resources: [(name: String, data: Data)] = []
    /// File name -> contents, for data/derived/.
    var derived: [(name: String, data: Data)] = []
}

/// Names of the generated resource files, in manifest order.
enum ResourceName {
    static let english = "english.txt"
    static let techAlways = "tech-always.txt"
    static let techCodeOnly = "tech-code-only.txt"
    /// The capitalized code-word list (ENG-R850 as amended on 16/11/2026).
    static let techCodeCapitalized = "tech-code-capitalized.txt"
    static let attested = "attested.txt"
    static let ambiguity = "ambiguity.tsv"
    static let notices = "NOTICES.txt"
    static let manifest = "manifest.json"
    static let attestedCandidates = "attested-candidates.tsv"
    // The collision lists (ENG-R825 to ENG-R828, ENG-R863).
    static let phrases = "phrases.txt"
    static let collisionSupplement = "collision-supplement.txt"
    static let boundaryParticles = "boundary-particles.txt"
    static let englishFunctionWords = "english-function-words.txt"
    static let englishLean = "english-lean-neutral.txt"
    static let tailWords = "vi-tail-words.txt"
    static let tailParticles = "vi-tail-particles.txt"
    static let preGuard = "english-pre-guard.txt"
    static let collisionLists = [
        phrases, collisionSupplement, boundaryParticles, englishFunctionWords, englishLean, tailWords, tailParticles,
        preGuard,
    ]
    static let all =
        [english, techAlways, techCodeOnly, techCodeCapitalized, attested, ambiguity] + collisionLists + [
            notices, manifest,
        ]
}

struct AttestedResult {
    var syllables: Set<String> = []
    var corpusTokens = 0
    var distinctTokens = 0
    var fromCorpus = 0
    var fromAdditions = 0
    var styleVariants = 0
    /// token -> occurrences in the legal texts (unfiltered candidate list).
    var counts: [String: Int] = [:]
}

enum Builder {
    /// The resource format (data/README.md). 2: the ambiguity table has the `run` and `viKind` columns and the
    /// collision lists ship (15/11/2026).
    static let resourceFormat = 2

    static func build(_ layout: Layout) throws -> BuildOutput {
        try InputManifest.verify(layout)
        let english = try EnglishLexicon.load(layout)
        let techAlways = try TechList.load(layout.inputs.appendingPathComponent("tech-always.txt"))
        let techCodeOnly = try TechList.load(layout.inputs.appendingPathComponent("tech-code-only.txt"))
        let techCodeCapitalized = try TechList.load(
            layout.inputs.appendingPathComponent(ResourceName.techCodeCapitalized))
        try checkCapitalizedCodeWords(techCodeCapitalized, codeOnly: Set(techCodeOnly))
        let ambiguity = try AmbiguityRow.load(layout.inputs.appendingPathComponent("ambiguity.tsv"))
        let attested = try attestedSyllables(layout)
        try checkGeneratedRows(
            ambiguity, english: english, techAlways: Set(techAlways), attested: attested.syllables)
        let collision = try CollisionInputs.load(layout)
        try checkCollisionInputs(
            collision, layout: layout, english: english, techAlways: Set(techAlways), attested: attested.syllables)

        var output = BuildOutput()
        let lists: [(String, [String])] = [
            (ResourceName.english, utf8Sorted(english.keys)),
            (ResourceName.techAlways, utf8Sorted(techAlways)),
            (ResourceName.techCodeOnly, utf8Sorted(techCodeOnly)),
            (ResourceName.techCodeCapitalized, utf8Sorted(techCodeCapitalized)),
            (ResourceName.attested, utf8Sorted(attested.syllables)),
        ]
        var entries: [String: Int] = [:]
        for (name, words) in lists {
            output.resources.append((name, Data(joinedLines(words).utf8)))
            entries[name] = words.count
        }
        let sortedRows = ambiguity.sorted { $0.raw.utf8.lexicographicallyPrecedes($1.raw.utf8) }
        output.resources.append(
            (ResourceName.ambiguity, Data(joinedLines([AmbiguityRow.header] + sortedRows.map(\.line)).utf8)))
        entries[ResourceName.ambiguity] = sortedRows.count
        for (name, words) in collisionLists(collision) {
            output.resources.append((name, Data(joinedLines(words).utf8)))
            entries[name] = words.count
        }
        output.resources.append((ResourceName.notices, Data(try notices(layout).utf8)))

        let stats: [(String, Int)] = [
            ("englishWords", english.count),
            ("legalTokens", attested.corpusTokens),
            ("legalDistinctTokens", attested.distinctTokens),
            ("attestedFromCorpus", attested.fromCorpus),
            ("attestedFromAdditions", attested.fromAdditions),
            ("attestedStyleVariants", attested.styleVariants),
        ]
        let inputsDigest = SHA256.hex(of: try FileIO.read(layout.manifestFile))
        output.resources.append(
            (
                ResourceName.manifest,
                Data(manifestJSON(output.resources, entries: entries, stats: stats, inputsDigest: inputsDigest).utf8)
            ))
        output.derived.append((ResourceName.attestedCandidates, Data(candidatesTSV(attested.counts).utf8)))
        return output
    }

    /// ENG-R850: a capitalized code word only keeps rule L9 for a word that L9 reads, so every entry must be on the
    /// code-only tech list; an entry that is not would silently do nothing.
    static func checkCapitalizedCodeWords(_ words: [String], codeOnly: Set<String>) throws {
        let missing = words.filter { !codeOnly.contains($0) }
        guard missing.isEmpty else {
            throw BuilderError(
                "\(ResourceName.techCodeCapitalized): not on tech-code-only.txt: \(missing.joined(separator: ", "))")
        }
    }

    /// The collision lists as resource files, in manifest order, each sorted by UTF-8 bytes.
    static func collisionLists(_ inputs: CollisionInputs) -> [(String, [String])] {
        [
            (ResourceName.phrases, utf8Sorted(inputs.phrases)),
            (ResourceName.collisionSupplement, utf8Sorted(inputs.supplement.map(\.raw))),
            (ResourceName.boundaryParticles, utf8Sorted(inputs.boundaryParticles)),
            (ResourceName.englishFunctionWords, utf8Sorted(inputs.functionWords)),
            (ResourceName.englishLean, utf8Sorted(inputs.englishLean)),
            (ResourceName.tailWords, utf8Sorted(inputs.tailWords.map(\.word))),
            (ResourceName.tailParticles, utf8Sorted(inputs.tailWords.filter(\.isParticle).map(\.word))),
            (ResourceName.preGuard, utf8Sorted(inputs.preGuard)),
        ]
    }

    /// The build checks of the collision lists (ENG-R826, ENG-R863). The phrase check reads the committed prose
    /// corpus when it exists (`check` regenerates the corpus and compares it, so CI always has it).
    static func checkCollisionInputs(
        _ inputs: CollisionInputs, layout: Layout, english: [String: Int], techAlways: Set<String>,
        attested: Set<String>
    ) throws {
        let typer = EngineTyper()
        try CollisionChecks.checkSupplement(
            inputs.supplement, english: english, techAlways: techAlways, attested: attested, typer: typer)
        if FileManager.default.fileExists(atPath: layout.corpusFile.path) {
            try CollisionChecks.checkPhrases(
                inputs.phrases, corpus: try FileIO.readUTF8(layout.corpusFile), typer: typer)
        }
    }

    /// A generated `en` row (docs/decisions/0202) restates what rule L8 or the tech-always list does. When the
    /// input it depends on changes (the display is attested, the word left the lexicon or the tech-always list),
    /// the row would keep restoring the word on its own (rule L11) and nobody would notice: fail instead.
    static func checkGeneratedRows(
        _ rows: [AmbiguityRow], english: [String: Int], techAlways: Set<String>, attested: Set<String>
    ) throws {
        var stale: [String] = []
        for row in rows {
            switch row.generatedReason {
            case .unattested:
                if attested.contains(row.display) {
                    stale.append("\(row.raw): display '\(row.display)' is now attested")
                } else if english[row.raw] == nil && !techAlways.contains(row.raw) {
                    stale.append("\(row.raw): no longer English (lexicon or tech-always), rule L8 does not apply")
                }
            case .techAlways:
                if !techAlways.contains(row.raw) { stale.append("\(row.raw): no longer in tech-always.txt") }
            case nil:
                break
            }
        }
        guard stale.isEmpty else {
            throw BuilderError(
                "ambiguity.tsv: generated rows whose reason no longer holds (delete each row, then merge again or "
                    + "decide it by hand):\n" + stale.joined(separator: "\n"))
        }
    }

    /// Attested set (spec/01-engine.md 8.2, used only by rule L8): legal-text tokens that are valid
    /// Tier A/B syllables per `Orthography.validity`, plus the reviewed hand additions, plus the other
    /// tone placement of open `oa`/`oe`/`uy` syllables so that both tone styles (5.2) find their display.
    static func attestedSyllables(_ layout: Layout) throws -> AttestedResult {
        var result = AttestedResult()
        for source in try LegalTexts.sources(layout) {
            let text = try FileIO.readUTF8(LegalTexts.textFile(layout, id: source.id))
            for token in VietnameseText.syllableTokens(text) {
                result.counts[token, default: 0] += 1
                result.corpusTokens += 1
            }
        }
        result.distinctTokens = result.counts.count
        var base = Set<String>()
        for token in result.counts.keys where Orthography.validity(of: token) != .invalid {
            base.insert(token)
        }
        result.fromCorpus = base.count
        let additions = try AttestedAdditions.load(layout.inputs.appendingPathComponent("attested-additions.txt"))
        let beforeAdditions = base.count
        base.formUnion(additions)
        result.fromAdditions = base.count - beforeAdditions
        var all = base
        for syllable in base {
            if let other = VietnameseText.otherToneStyle(of: syllable) { all.insert(other) }
        }
        result.styleVariants = all.count - base.count
        result.syllables = all
        return result
    }

    /// Unfiltered tokens with their counts, most frequent first: lets reviewers see the data before the
    /// engine's validator exists, and is the corpus frequency proxy for `ambiguity-candidates`.
    static func candidatesTSV(_ counts: [String: Int]) -> String {
        let rows = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
        }
        return joinedLines(["token\tcount"] + rows.map { "\($0.key)\t\($0.value)" })
    }

    /// NOTICES.txt: data/licenses/bundled-notices.txt with `@include <file>` lines replaced by the
    /// named file from data/licenses/ (ENG-R811).
    static func notices(_ layout: Layout) throws -> String {
        let template = try FileIO.readUTF8(layout.licenses.appendingPathComponent("bundled-notices.txt"))
        var lines: [String] = []
        for line in template.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@include ") {
                let name = line.dropFirst("@include ".count).trimmingCharacters(in: .whitespaces)
                let data = try FileIO.read(layout.licenses.appendingPathComponent(name))
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                lines.append(
                    contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map {
                        $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                    })
            } else {
                lines.append(String(line))
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return joinedLines(lines)
    }

    /// Hand-written JSON with a fixed key order (JSONEncoder's ordering and escaping are not part of
    /// its contract, so it is avoided for byte-reproducible output).
    static func manifestJSON(
        _ files: [(name: String, data: Data)], entries: [String: Int], stats: [(String, Int)], inputsDigest: String
    ) -> String {
        var lines = [
            "{", "  \"format\": \(resourceFormat),", "  \"generator\": \"lexicon-builder\",",
            "  \"inputsSHA256\": \"\(inputsDigest)\",", "  \"files\": [",
        ]
        for (index, file) in files.enumerated() {
            let comma = index == files.count - 1 ? "" : ","
            let count = entries[file.name].map { ", \"entries\": \($0)" } ?? ""
            lines.append(
                "    {\"name\": \"\(file.name)\", \"bytes\": \(file.data.count)\(count), \"sha256\": \"\(SHA256.hex(of: file.data))\"}\(comma)"
            )
        }
        lines.append("  ],")
        lines.append("  \"stats\": {")
        for (index, stat) in stats.enumerated() {
            lines.append("    \"\(stat.0)\": \(stat.1)\(index == stats.count - 1 ? "" : ",")")
        }
        lines.append("  }")
        lines.append("}")
        return joinedLines(lines)
    }

    static func write(_ output: BuildOutput, resources: URL, derived: URL) throws {
        for file in output.resources { try FileIO.write(file.data, to: resources.appendingPathComponent(file.name)) }
        for file in output.derived { try FileIO.write(file.data, to: derived.appendingPathComponent(file.name)) }
    }
}
