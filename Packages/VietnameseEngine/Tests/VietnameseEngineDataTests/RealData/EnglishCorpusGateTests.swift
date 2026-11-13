// SPDX-License-Identifier: MPL-2.0
//
// ENG-T10 and ENG-T11 with the bundled data: every word of the English lexicon and of both tech lists,
// typed in Telex with default options and committed by a space, (a) after an English seed token
// (ENG-R871) and (b) after a Vietnamese seed token (ENG-R872). The tests print every changed word with
// the rule that changed it.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T10 English corpus with the bundled data")
struct EnglishCorpusGateTests {
    /// Both runs are computed once and shared by the two tests.
    private static let report = Result { () throws -> (words: [String], report: EnglishCorpusReport) in
        let words = try RealData.englishCorpusWords()
        return (words, EnglishCorpusCheck.run(words: words, resources: try RealData.resources()))
    }

    @Test("ENG-R871, ENG-T11: at least 99.5 % unchanged in an English run, every failure a known exception")
    func englishRun() throws {
        let (words, report) = try Self.report.get()
        let exceptions = EnglishCorpusCheck.exceptions(
            try String(contentsOf: RealData.knownExceptionsFile, encoding: .utf8))
        let changed = report.changedInEnglishRun
        // The share counts every changed word, listed or not: an exception explains a failure, it does not
        // make the word unchanged.
        let unchanged = Double(words.count - changed.count) / Double(words.count)
        print(
            "[ENG-R871] \(words.count) words, \(changed.count) changed in an English run, unchanged "
                + String(format: "%.4f %%", unchanged * 100) + ":\n" + RealData.listing(changed))
        #expect(words.count > 40_000)
        #expect(unchanged >= 0.995)
        let unlisted = changed.filter { !exceptions.contains($0.word) }
        #expect(unlisted.isEmpty, "not in known-exceptions.txt:\n\(RealData.listing(unlisted))")
        let stale = exceptions.subtracting(changed.map(\.word)).sorted()
        #expect(stale.isEmpty, "known exceptions that no longer change: \(stale)")
    }

    @Test("ENG-R872: at most 3 % changed in Vietnamese context, every change a vi row of the ambiguity table")
    func vietnameseContext() throws {
        let (words, report) = try Self.report.get()
        let resources = try RealData.resources()
        let changed = report.changedInVietnameseContext
        print(
            "[ENG-R872] \(words.count) words, \(changed.count) changed in Vietnamese context ("
                + String(format: "%.3f %%", report.changedShareInVietnameseContext * 100) + "):\n"
                + RealData.listing(changed))
        #expect(report.changedShareInVietnameseContext <= 0.03)
        // 100 % of the changed words are rows decided vi (proposed, reviewed or unreviewed, ENG-R821) whose
        // display is an attested Tier A syllable (ENG-R820). The ENG-T11 exceptions of the same corpus are
        // the only other changes: rules L4 and L6 decide them before the context or the table is read, so
        // each must change exactly as in the English run (docs/decisions/0202).
        let englishRun = Dictionary(
            report.changedInEnglishRun.map { ($0.word, $0.committed) }, uniquingKeysWith: { first, _ in first })
        let exceptions = Set(englishRun.keys).intersection(
            EnglishCorpusCheck.exceptions(try String(contentsOf: RealData.knownExceptionsFile, encoding: .utf8)))
        let documented = changed.filter { exceptions.contains($0.word) }
        #expect(documented.allSatisfy { englishRun[$0.word] == $0.committed })
        let rest = changed.filter { !exceptions.contains($0.word) }
        let withoutViRow = rest.filter { resources.ambiguity[$0.word] != .vietnamese }
        #expect(withoutViRow.isEmpty, "changed without a vi row:\n\(RealData.listing(withoutViRow))")
        let candidates = Set(report.unexplainedVietnameseChanges(resources: resources).map(\.word))
        let unexplained = rest.filter { candidates.contains($0.word) }
        #expect(unexplained.isEmpty, "not an ambiguity candidate:\n\(RealData.listing(unexplained))")
        print("[ENG-R872] \(rest.count) vi rows, \(documented.count) known exceptions (rules L4, L6)")
    }
}
