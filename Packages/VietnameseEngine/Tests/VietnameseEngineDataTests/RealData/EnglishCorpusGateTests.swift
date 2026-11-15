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

    /// The same run with `lookaheadRevision` off: the engine as it was before the collision rules (ENG-R829).
    private static let reportWithoutCollisionRules = Result { () throws -> EnglishCorpusReport in
        EnglishCorpusCheck.run(
            words: try RealData.englishCorpusWords(), resources: try RealData.resources(),
            configuration: EngineConfiguration(lookaheadRevision: false))
    }

    @Test("ENG-R871, ENG-T11: at least 99.5 % unchanged in an English run, every failure a known exception")
    func englishRun() throws {
        let (words, report) = try Self.report.get()
        let resources = try RealData.resources()
        let exceptions = EnglishCorpusCheck.exceptions(
            try String(contentsOf: RealData.knownExceptionsFile, encoding: .utf8))
        // ENG-R827: a `run: vi` row is never restored by the English run; L11 keeps it Vietnamese by design.
        let runExempt = report.changedInEnglishRun.filter {
            resources.collision.runExempt.contains($0.word) && $0.decision == .kept(.ambiguityTable)
        }
        print("[ENG-R871] \(runExempt.count) run: vi rows kept Vietnamese in the English run (ENG-R827)")
        #expect(runExempt.count == resources.collision.runExempt.count(in: words))
        let changed = report.changedInEnglishRun.filter { !runExempt.contains($0) }
        // The share counts every changed word, listed or not, `run: vi` rows included: an exception explains a
        // failure, it does not make the word unchanged.
        let unchanged = Double(words.count - report.changedInEnglishRun.count) / Double(words.count)
        print(
            "[ENG-R871] \(words.count) words, \(report.changedInEnglishRun.count) changed in an English run, unchanged "
                + String(format: "%.4f %%", unchanged * 100) + "; besides the run: vi rows:\n"
                + RealData.listing(changed))
        #expect(words.count > 40_000)
        #expect(unchanged >= 0.995)
        let unlisted = changed.filter { !exceptions.contains($0.word) }
        #expect(unlisted.isEmpty, "not in known-exceptions.txt:\n\(RealData.listing(unlisted))")
        let stale = exceptions.subtracting(changed.map(\.word)).sorted()
        #expect(stale.isEmpty, "known exceptions that no longer change: \(stale)")
    }

    @Test("ENG-R829: with lookaheadRevision off the English run changes exactly the known exceptions")
    func englishRunWithoutTheCollisionRules() throws {
        let report = try Self.reportWithoutCollisionRules.get()
        let exceptions = EnglishCorpusCheck.exceptions(
            try String(contentsOf: RealData.knownExceptionsFile, encoding: .utf8))
        #expect(Set(report.changedInEnglishRun.map(\.word)) == exceptions)
        // Vietnamese context does not depend on the collision rules.
        let (_, withRules) = try Self.report.get()
        #expect(report.changedInVietnameseContext == withRules.changedInVietnameseContext)
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
        // the only other changes: rules L4, L6 and L7 decide them before the context or the table is read, so
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
        print("[ENG-R872] \(rest.count) vi rows, \(documented.count) known exceptions (rules L4, L6, L7)")
    }
}

extension WordSet {
    /// How many of `words` are in the set.
    fileprivate func count(in words: [String]) -> Int { words.reduce(0) { $0 + (contains($1) ? 1 : 0) } }
}
