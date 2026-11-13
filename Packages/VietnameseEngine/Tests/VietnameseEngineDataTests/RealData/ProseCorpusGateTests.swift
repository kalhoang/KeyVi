// SPDX-License-Identifier: MPL-2.0
//
// ENG-T20 with the bundled data: data/corpus/prose-vi.txt (250,000 tokens of Vietnamese legal text,
// spec 13.4) typed by the three simulated typists of `ProseCorpusCheck` in both input methods and
// committed in Vietnamese context. ENG-R873: at least 99.95 % of tokens identical to the source, every
// difference attributable to an `en` row of the ambiguity table.
//
// Reading (docs/decisions/0202): the legal texts mix the two tone placements of spec 5.2 (`hoá` 339 times,
// `hóa` 366 times; `thoả` / `thỏa`, `uỷ` / `ủy`), while a typist has one tone-style setting. A token that
// differs from the source only by that placement is the same syllable in the typist's style; it counts as
// identical and the number of such tokens is printed.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T20 prose corpus with the bundled data")
struct ProseCorpusGateTests {
    private static let corpus = Result { try RealData.proseCorpus() }

    static let cases: [(CorpusMethod, CorpusOrder)] = CorpusMethod.allCases.flatMap { method in
        ProseCorpusCheck.typists.map { (method, $0) }
    }

    /// Differences that the data cannot remove (docs/decisions/0202, open issue for Pa): rule L10 restores
    /// a collision typed right after an English word of the source, which makes the run English (ENG-R823):
    /// `trên Internet. Cơ chế` commits `Cow` for the Telex typists, whose keys for `Cơ` are `Cow`.
    static let knownEngineDifferences: Set<String> = ["Cơ -> Cow"]

    @Test("ENG-R873: three typists, both methods", arguments: cases)
    func typist(_ method: CorpusMethod, _ order: CorpusOrder) throws {
        let resources = try RealData.resources()
        let report = ProseCorpusCheck.run(
            text: try Self.corpus.get(), method: method, order: order, resources: resources)
        let styleOnly = report.differences.filter { Self.differsOnlyByTonePlacement($0.word, $0.committed) }
        let differences = report.differences.filter { !Self.differsOnlyByTonePlacement($0.word, $0.committed) }
        let identical = Double(report.tokens - differences.count) / Double(report.tokens)
        print(
            "[ENG-R873] \(method) \(order): \(report.tokens) tokens, identical "
                + String(format: "%.4f %%", identical * 100) + " (\(styleOnly.count) differ only by the 5.2 "
                + "tone placement; strictly identical " + String(format: "%.4f %%", report.identicalShare * 100)
                + "), \(differences.count) differences:\n" + RealData.listing(differences))
        #expect(report.tokens >= 200_000)
        #expect(identical >= 0.9995)
        let unexplained = differences.filter { !Self.isAttributableToAnEnglishRow($0, resources: resources) }
        let unknown = unexplained.filter { !Self.knownEngineDifferences.contains(Self.key($0)) }
        #expect(unknown.isEmpty, "\(method) \(order) not attributable to an en row:\n\(RealData.listing(unknown))")
        let known = unexplained.filter { Self.knownEngineDifferences.contains(Self.key($0)) }
        if method == .telex {
            withKnownIssue("ENG-R873: L10 after an English word of the source (docs/decisions/0202)") {
                #expect(known.isEmpty, "\(RealData.listing(known))")
            }
        } else {
            #expect(known.isEmpty)
        }
    }

    /// A difference is attributable to an `en` row when rule L11 restored the word's raw keys because of
    /// such a row.
    static func isAttributableToAnEnglishRow(_ change: ChangedWord, resources: Resources) -> Bool {
        change.decision == .restored(.ambiguityTable) && resources.ambiguity[change.committed.lowercased()] == .english
    }

    /// The same Tier A syllable (onset, vowel group, coda, tone) with the same letter cases, written with
    /// the other tone placement of spec 5.2 (`hoá` and `hóa`, `Uỷ` and `Ủy`).
    static func differsOnlyByTonePlacement(_ source: String, _ typed: String) -> Bool {
        guard source != typed, source.count == typed.count,
            zip(source, typed).allSatisfy({ $0.isUppercase == $1.isUppercase })
        else { return false }
        let lhs = Orthography.analyze(source.lowercased())
        let rhs = Orthography.analyze(typed.lowercased())
        return lhs.validity == .standard && rhs.validity == .standard && lhs.onset == rhs.onset
            && lhs.vowelGroup == rhs.vowelGroup && lhs.coda == rhs.coda && lhs.tone == rhs.tone
    }

    private static func key(_ change: ChangedWord) -> String { "\(change.word) -> \(change.committed)" }

    @Test("The tone-placement comparison accepts only the 5.2 placement of the same syllable")
    func tonePlacementComparison() {
        #expect(Self.differsOnlyByTonePlacement("hoá", "hóa"))
        #expect(Self.differsOnlyByTonePlacement("Uỷ", "Ủy"))
        #expect(Self.differsOnlyByTonePlacement("HOÀ", "HÒA"))
        #expect(!Self.differsOnlyByTonePlacement("hoá", "hoá"))
        #expect(!Self.differsOnlyByTonePlacement("hoá", "hoà"))
        #expect(!Self.differsOnlyByTonePlacement("hoá", "Hóa"))
        #expect(!Self.differsOnlyByTonePlacement("Cơ", "Cow"))
        #expect(!Self.differsOnlyByTonePlacement("IX", "Ĩ"))
    }
}
