// SPDX-License-Identifier: MPL-2.0
//
// ENG-T20 with the bundled data: data/corpus/prose-vi.txt (250,000 tokens of Vietnamese legal text,
// spec 13.4) typed by the three simulated typists of `ProseCorpusCheck` in both input methods and
// committed in Vietnamese context. ENG-R873: at least 99.95 % of tokens identical to the source, every
// difference attributable to an `en` row of the ambiguity table.
//
// Reading (docs/decisions/0202): the legal texts mix the two tone placements of spec 5.2 (`hoá` 339 times,
// `hóa` 366 times; `thoả` / `thỏa`, `uỷ` / `ủy`), while a typist has one tone-style setting. The typists run in
// both styles. A token whose typed form is exactly the source syllable spelled by the independent oracle in the
// typist's own style (`hoá` typed `hóa` by a traditional typist, never the reverse) counts as identical; the
// number of such tokens and the strict share are printed. A typist that writes the other style's placement is a
// difference, so the relaxation cannot hide a tone-placement regression.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T20 prose corpus with the bundled data")
struct ProseCorpusGateTests {
    private static let corpus = Result { try RealData.proseCorpus() }

    static let cases: [(CorpusMethod, CorpusOrder, ToneStyle)] = CorpusMethod.allCases.flatMap { method in
        ProseCorpusCheck.typists.flatMap { order in [ToneStyle.traditional, .modern].map { (method, order, $0) } }
    }

    /// Differences that the data cannot remove (docs/decisions/0202, open issue for Pa): rule L10 restores
    /// a collision typed right after an English word of the source, which makes the run English (ENG-R823):
    /// `trên Internet. Cơ chế` commits `Cow` for the Telex typists, whose keys for `Cơ` are `Cow`.
    static let knownEngineDifferences: Set<String> = ["Cơ -> Cow"]

    @Test("ENG-R873: three typists, both methods, both tone styles", arguments: cases)
    func typist(_ method: CorpusMethod, _ order: CorpusOrder, _ style: ToneStyle) throws {
        let resources = try RealData.resources()
        let report = ProseCorpusCheck.run(
            text: try Self.corpus.get(), method: method, order: order, style: style, resources: resources)
        let styleOnly = report.differences.filter { Self.isSourceInTypistStyle($0.word, $0.committed, style: style) }
        let differences = report.differences.filter {
            !Self.isSourceInTypistStyle($0.word, $0.committed, style: style)
        }
        let identical = Double(report.tokens - differences.count) / Double(report.tokens)
        print(
            "[ENG-R873] \(method) \(order) \(style): \(report.tokens) tokens, identical "
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

    /// `typed` differs from `source` and is exactly the source syllable (onset, rhyme, tone, letter case) spelled
    /// by `SyllableOracle` with the tone placement of `style` (spec 5.1, 5.2): `hoá` typed `hóa` in the
    /// traditional style, `hóa` typed `hoá` in the modern style, and nothing else.
    static func isSourceInTypistStyle(_ source: String, _ typed: String, style: ToneStyle) -> Bool {
        guard source != typed, let casing = casing(of: source) else { return false }
        let analysis = Orthography.analyze(source.lowercased())
        guard analysis.validity == .standard else { return false }
        let spelled = SyllableOracle.spell(
            onset: analysis.onset, rhyme: analysis.vowelGroup + analysis.coda, tone: analysis.tone, style: style,
            casing: casing)
        return typed == spelled
    }

    private static func casing(of word: String) -> SyllableOracle.Casing? {
        guard let first = word.first else { return nil }
        let rest = word.dropFirst()
        if word.allSatisfy(\.isLowercase) { return .lowercase }
        if word.count > 1, word.allSatisfy(\.isUppercase) { return .uppercase }
        return first.isUppercase && rest.allSatisfy(\.isLowercase) ? .titlecase : nil
    }

    private static func key(_ change: ChangedWord) -> String { "\(change.word) -> \(change.committed)" }

    @Test("The tone-placement comparison accepts only the typist's own 5.2 placement of the same syllable")
    func tonePlacementComparison() {
        #expect(Self.isSourceInTypistStyle("hoá", "hóa", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("hóa", "hoá", style: .traditional), "a modern placement is a regression")
        #expect(Self.isSourceInTypistStyle("hóa", "hoá", style: .modern))
        #expect(!Self.isSourceInTypistStyle("hoá", "hóa", style: .modern))
        #expect(Self.isSourceInTypistStyle("Uỷ", "Ủy", style: .traditional))
        #expect(Self.isSourceInTypistStyle("HOÀ", "HÒA", style: .traditional))
        #expect(Self.isSourceInTypistStyle("Thoả", "Thỏa", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("hoá", "hoá", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("hoá", "hoà", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("hoá", "Hóa", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("hOá", "hÓa", style: .traditional), "mixed case is not a syllable case")
        #expect(!Self.isSourceInTypistStyle("Cơ", "Cow", style: .traditional))
        #expect(!Self.isSourceInTypistStyle("IX", "Ĩ", style: .traditional))
    }
}
