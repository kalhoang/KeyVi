// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The QA-R4 corpus of spec/04-quality-release.md: every case file in `QACorpus.caseFiles` (rhymes-rare,
/// no-shortcuts, macros, proper-nouns, english, collisions, editing, crash-regressions, restore-exact,
/// layouts) is read by one loader and every case runs through an `InvariantChecker`, so the fuzz
/// invariants of 13.6 hold after every event of every case as well as the expected text.
@Suite("QA-R4 corpus files")
struct QACorpusTests {
    static let macroTable: MacroTable = {
        do {
            return try QACorpus.macroTable(tsv: CorpusFiles.text(QACorpus.macroTableFile))
        } catch {
            Issue.record("cannot load \(QACorpus.macroTableFile): \(error)")
            return .empty
        }
    }()

    static func load(_ file: String) -> [QACorpusCase] {
        do {
            return try QACorpus.cases(file: file, tsv: CorpusFiles.text(file))
        } catch {
            Issue.record("cannot load \(file): \(error)")
            return []
        }
    }

    static let cases: [QACorpusCase] = QACorpus.caseFiles.flatMap(load)

    @Test func filesAreComplete() throws {
        for file in QACorpus.caseFiles {
            #expect(Self.cases.contains { $0.file == file }, "\(file) has no cases")
        }
        #expect(Set(Self.cases.map(\.id)).count == Self.cases.count, "duplicate ids")
        #expect(!Self.macroTable.isEmpty)
        // Every file in the corpus folder is either a case file or a fixture file.
        let folder = try #require(Bundle.module.url(forResource: "Corpus", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tsv") }
        #expect(Set(names) == Set(QACorpus.caseFiles + QACorpus.fixtureFiles))
        print("[QA-R4] \(Self.cases.count) cases in \(QACorpus.caseFiles.count) files")
    }

    @Test(arguments: cases)
    func corpusCase(_ corpusCase: QACorpusCase) throws {
        let (text, restore) = try QACorpus.run(corpusCase, macros: Self.macroTable)
        #expect(text == corpusCase.expected, "\(corpusCase): \(corpusCase.note)")
        if let expectedRestore = corpusCase.expectedRestore {
            #expect(restore == expectedRestore, "\(corpusCase) restore: \(corpusCase.note)")
        }
    }

    @Test func repetitionNotation() throws {
        #expect(try QACorpus.expandRepetitions("a«bc»×3d", file: "x", line: 1) == "abcbcbcd")
        #expect(
            try QACorpus.expandRepetitions("«k»×33\\s", file: "x", line: 1) == String(repeating: "k", count: 33) + "\\s"
        )
        #expect(throws: FixtureError.self) { try QACorpus.expandRepetitions("«ab×3", file: "x", line: 1) }
        #expect(throws: FixtureError.self) { try QACorpus.expandRepetitions("«ab»3", file: "x", line: 1) }
        #expect(throws: FixtureError.self) { try QACorpus.expandRepetitions("«ab»×0", file: "x", line: 1) }
    }
}
