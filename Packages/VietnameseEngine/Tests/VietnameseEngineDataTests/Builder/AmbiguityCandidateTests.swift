// SPDX-License-Identifier: MPL-2.0
//
// In-process tests of the ENG-R820 candidate generator and the ENG-R821 merge policy of lexicon-builder,
// including the extension of docs/decisions/0202: English words whose display is a valid but unattested
// Tier A syllable (restored by rule L8) and words that change only in VNI (digits, ENG-R874).

import Foundation
import Testing
import VietnameseEngine

@testable import lexicon_builder

/// A fake engine: a display per (method, raw), optionally a different modern-style display; every other
/// word is typed unchanged.
private struct FakeTyper: CandidateTyper {
    var telex: [String: String] = [:]
    var vni: [String: String] = [:]
    var modern: [String: String] = [:]
    var validities: [String: Validity] = [:]

    func display(typing raw: String, method: CandidateMethod, style: ToneStyle) -> String {
        if style == .modern, method == .telex, let display = modern[raw] { return display }
        return (method == .telex ? telex[raw] : vni[raw]) ?? raw
    }

    func validity(of display: String) -> Validity { validities[display] ?? .invalid }
}

private func inputs(
    english: [String: Int], techAlways: [String] = [], techCodeOnly: [String] = [], attested: Set<String>,
    counts: [String: Int] = [:], rows: [String: String] = [:]
) -> CandidateInputs {
    CandidateInputs(
        english: english, techAlways: techAlways, techCodeOnly: techCodeOnly, attested: attested, counts: counts,
        rows: rows)
}

@Suite struct AmbiguityCandidateTests {
    private let typer = FakeTyper(
        telex: [
            "as": "á", "is": "í", "exe": "ễ", "sed": "sẹ", "theme": "thêm", "www": "ww", "chose": "chóe",
            "the": "the",
        ],
        vni: ["a4": "ã", "as": "WRONG"],
        modern: ["chose": "choé"],
        validities: [
            "á": .standard, "í": .standard, "ễ": .standard, "sẹ": .standard, "thêm": .extended, "ww": .invalid,
            "chóe": .standard, "choé": .standard, "ã": .standard,
        ])

    @Test func attestedEnglishDisplayIsAViUnreviewedCandidate() throws {
        let result = AmbiguityCandidates.candidates(
            inputs(english: ["as": 10], attested: ["á"], counts: ["á": 7]), typer: typer)
        #expect(result.count == 1)
        let candidate = try #require(result.first)
        #expect(candidate.attested)
        #expect(candidate.isEnglish)
        #expect(candidate.corpusCount == 7)
        #expect(candidate.mergeRow.decision == .vi)
        #expect(candidate.mergeRow.status == .unreviewed)
        #expect(candidate.mergeRow.display == "á")
        #expect(candidate.mergeRow.generatedReason == nil, "a vi/unreviewed row has no reason to re-check")
    }

    @Test func unattestedEnglishDisplayIsProposedEnBecauseL8RestoresIt() throws {
        let result = AmbiguityCandidates.candidates(inputs(english: ["is": 10], attested: []), typer: typer)
        let candidate = try #require(result.first)
        #expect(candidate.attested == false)
        #expect(candidate.mergeRow.decision == .en)
        #expect(candidate.mergeRow.status == .proposed)
        #expect(candidate.mergeRow.note.contains("not attested"))
        #expect(candidate.mergeRow.note.contains("L8"))
        #expect(candidate.mergeRow.generatedReason == .unattested)
    }

    @Test func techAlwaysCandidateIsProposedEnSoThatItStaysAsTyped() throws {
        let result = AmbiguityCandidates.candidates(
            inputs(english: [:], techAlways: ["exe"], attested: ["ễ"]), typer: typer)
        let candidate = try #require(result.first)
        #expect(candidate.source == "tech-always")
        #expect(candidate.isEnglish)
        #expect(candidate.mergeRow.decision == .en)
        #expect(candidate.mergeRow.status == .proposed)
        #expect(candidate.mergeRow.note.contains("tech-always"))
        #expect(candidate.mergeRow.generatedReason == .techAlways)
    }

    @Test func codeOnlyWordOutsideTheLexiconIsViUnreviewedEvenWhenUnattested() throws {
        // Rule L7 keeps it in the general context whatever the table says, so the row records vi.
        let result = AmbiguityCandidates.candidates(
            inputs(english: [:], techCodeOnly: ["sed"], attested: []), typer: typer)
        let candidate = try #require(result.first)
        #expect(!candidate.isEnglish)
        #expect(!candidate.attested)
        #expect(candidate.mergeRow.decision == .vi)
        #expect(candidate.mergeRow.status == .unreviewed)
    }

    @Test func invalidExtendedAndUnchangedDisplaysAreNotCandidates() {
        let result = AmbiguityCandidates.candidates(
            inputs(english: ["theme": 35, "the": 10], techAlways: ["www"], attested: ["thêm"]), typer: typer)
        #expect(result.isEmpty)
    }

    @Test func bothToneStylesAreReportedAndBothMustBeAttested() throws {
        let partly = AmbiguityCandidates.candidates(
            inputs(english: ["chose": 10], attested: ["chóe"]), typer: typer)
        let candidate = try #require(partly.first)
        #expect(candidate.traditional == "chóe")
        #expect(candidate.modern == "choé")
        #expect(!candidate.attested, "the modern display is not attested, so L8 restores it in modern style")
        let fully = AmbiguityCandidates.candidates(
            inputs(english: ["chose": 10], attested: ["chóe", "choé"]), typer: typer)
        #expect(fully.first?.attested == true)
    }

    @Test func wordsWithDigitsAreAlsoTypedInVNI() throws {
        // ENG-R874: a word without digits never changes in VNI, so only words with digits are typed there.
        let result = AmbiguityCandidates.candidates(
            inputs(english: ["as": 10], techAlways: ["a4"], attested: ["á"]), typer: typer)
        #expect(result.map(\.raw) == ["as", "a4"])
        let vni = try #require(result.last)
        #expect(vni.method == .vni)
        #expect(vni.traditional == "ã")
        #expect(vni.mergeRow.decision == .en)
        #expect(result.first?.method == .telex)
    }

    @Test func candidatesAreSortedByLevelThenCorpusCountThenRawKeys() {
        let typer = FakeTyper(
            telex: ["bb": "bá", "aa": "bá", "cc": "cá", "dd": "đá"],
            validities: ["bá": .standard, "cá": .standard, "đá": .standard])
        let result = AmbiguityCandidates.candidates(
            inputs(
                english: ["bb": 20, "aa": 20, "cc": 10], techCodeOnly: ["dd"], attested: ["bá", "cá", "đá"],
                counts: ["cá": 1, "bá": 3]),
            typer: typer)
        #expect(result.map(\.raw) == ["cc", "aa", "bb", "dd"])
        #expect(result.last?.rank == AmbiguityCandidates.techRank)
    }

    @Test func tsvShowsTheMergeRowAndTheCurrentRow() {
        let result = AmbiguityCandidates.candidates(
            inputs(english: ["as": 10, "is": 10], attested: ["á"], rows: ["as": "vi/proposed"]), typer: typer)
        #expect(
            AmbiguityCandidates.tsv(result) == """
                raw\tmethod\ttraditional\tmodern\tattested\tsource\tcorpus_count\tmerge_as\tcurrent_row
                as\ttelex\tá\tá\tyes\tscowl-10\t0\tvi/unreviewed\tvi/proposed
                is\ttelex\tí\tí\tno\tscowl-10\t0\ten/proposed\t-

                """)
    }

    @Test func mergeAppendsOnlyMissingRowsAndKeepsExistingDecisions() throws {
        let directory = try TempDirectory.make("merge")
        defer { TempDirectory.remove(directory) }
        let table = directory.appendingPathComponent("ambiguity.tsv")
        // No final newline: the merge must add one before appending.
        try write("# comment\n\(AmbiguityRow.header)\nas\ten\treviewed\tá\tPa", to: table)
        let result = AmbiguityCandidates.candidates(
            inputs(english: ["as": 10, "is": 10], techAlways: ["exe"], attested: ["á", "ễ"]), typer: typer)
        #expect(try AmbiguityCandidates.merge(result, into: table) == 2)
        let rows = try AmbiguityRow.load(table)
        #expect(rows.map(\.raw) == ["as", "is", "exe"])
        #expect(rows[0] == AmbiguityRow(raw: "as", decision: .en, status: .reviewed, display: "á", note: "Pa"))
        #expect(rows[1].decision == .en && rows[1].status == .proposed)
        #expect(rows[2].decision == .en && rows[2].status == .proposed)
        #expect(try AmbiguityCandidates.merge(result, into: table) == 0)
    }

    @Test func mergeGroupsGeneratedEnRowsUnderTheirOwnBlockAndViRowsBeforeIt() throws {
        // Medium review finding: the generated en rows are not Pa's decisions; they live in one block at the
        // end so that the ENG-R821 review list (hand rows and vi/unreviewed candidates) stays readable.
        let directory = try TempDirectory.make("merge-block")
        defer { TempDirectory.remove(directory) }
        let table = directory.appendingPathComponent("ambiguity.tsv")
        try write("# comment\n\(AmbiguityRow.header)\ntest\ten\tproposed\ttét\tPa\n", to: table)
        let typer = FakeTyper(
            telex: ["as": "á", "is": "í", "exe": "ễ", "sed": "sẹ"],
            validities: ["á": .standard, "í": .standard, "ễ": .standard, "sẹ": .standard])
        let first = AmbiguityCandidates.candidates(
            inputs(english: ["as": 10, "is": 10], techAlways: ["exe"], attested: ["á", "ễ"]), typer: typer)
        #expect(try AmbiguityCandidates.merge(first, into: table) == 3)
        var lines = try FileIO.readUTF8(table).split(separator: "\n").map(String.init)
        var marker = try #require(lines.firstIndex { $0.hasPrefix(AmbiguityCandidates.generatedBlockMarker) })
        #expect(lines.prefix(marker).contains { $0.hasPrefix("as\tvi\tunreviewed") })
        #expect(lines.suffix(from: marker).contains { $0.hasPrefix("is\ten\tproposed") })
        #expect(lines.suffix(from: marker).contains { $0.hasPrefix("exe\ten\tproposed") })
        // A second merge keeps one block: vi rows go before it, en rows at its end.
        let second = AmbiguityCandidates.candidates(
            inputs(english: ["is": 10], techAlways: ["exe"], techCodeOnly: ["sed"], attested: ["ễ"]), typer: typer)
        #expect(try AmbiguityCandidates.merge(second, into: table) == 1)
        lines = try FileIO.readUTF8(table).split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix(AmbiguityCandidates.generatedBlockMarker) }.count == 1)
        marker = try #require(lines.firstIndex { $0.hasPrefix(AmbiguityCandidates.generatedBlockMarker) })
        #expect(lines.prefix(marker).contains { $0.hasPrefix("sed\tvi\tunreviewed") })
        #expect(try AmbiguityRow.load(table).map(\.raw) == ["test", "as", "sed", "is", "exe"])
    }

    @Test func generatedReasonIsReadFromTheNoteToken() {
        func row(_ note: String) -> AmbiguityRow {
            AmbiguityRow(raw: "is", decision: .en, status: .proposed, display: "í", note: note)
        }
        #expect(row("x [generated:unattested] y").generatedReason == .unattested)
        #expect(row("[generated:tech-always]").generatedReason == .techAlways)
        #expect(row("hand-written, mentions generated candidate").generatedReason == nil)
    }

    @Test func tableTyperReadsAnOptionalMethodColumn() throws {
        let directory = try TempDirectory.make("table-typer")
        defer { TempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("fake.tsv")
        try write("as\tá\tá\tstandard\na4\tã\tã\tstandard\tvni\n", to: file)
        let table = try TableTyper(file)
        #expect(table.display(typing: "as", method: .telex, style: .traditional) == "á")
        #expect(table.display(typing: "as", method: .vni, style: .traditional) == "as")
        #expect(table.display(typing: "a4", method: .vni, style: .modern) == "ã")
        #expect(table.display(typing: "a4", method: .telex, style: .modern) == "a4")
        #expect(table.validity(of: "ã") == .standard)
        try write("as\tá\tá\tstandard\tqwerty\n", to: file)
        #expect(throws: BuilderError.self) { try TableTyper(file) }
        try write("as\tá\tá\tbogus\n", to: file)
        #expect(throws: BuilderError.self) { try TableTyper(file) }
        try write("as\tá\n", to: file)
        #expect(throws: BuilderError.self) { try TableTyper(file) }
    }

    @Test func realEngineTyperTypesTelexAndVNI() {
        let engine = EngineTyper()
        #expect(engine.display(typing: "as", method: .telex, style: .traditional) == "á")
        #expect(engine.display(typing: "hoaf", method: .telex, style: .traditional) == "hòa")
        #expect(engine.display(typing: "hoaf", method: .telex, style: .modern) == "hoà")
        #expect(engine.display(typing: "a4", method: .vni, style: .traditional) == "ã")
        #expect(engine.validity(of: "á") == .standard)
    }

    @Test func realEngineTyperReportsWordsThatSplitIntoTokensAsUnchanged() {
        // In Telex a digit is a boundary: `h2o` commits `h` and `2` and leaves `o` composing, which is not
        // the word's display. Such words are reported unchanged, so `h2o` and `m4a` are not candidates.
        let engine = EngineTyper()
        for word in ["a4", "h2o", "m4a", "4g", "mp3"] {
            #expect(engine.display(typing: word, method: .telex, style: .traditional) == word)
        }
        #expect(engine.display(typing: "h2o", method: .vni, style: .traditional) == "h2o")
    }
}
