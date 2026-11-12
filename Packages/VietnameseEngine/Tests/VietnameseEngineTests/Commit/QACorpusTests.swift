// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The hand-curated QA-R4 corpus files of spec/04-quality-release.md for sections 7.4, 10 and 11:
/// `macros.tsv` (with `macro-table.tsv`) and `editing.tsv`. Every case runs through the engine driver,
/// so the simulated field is checked against the engine's view after every event (ENG-T31).
@Suite("QA-R4 corpus: macros and editing")
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

    static let macroCases = load(QACorpus.macrosFile)
    static let editingCases = load(QACorpus.editingFile)

    @Test func filesAreComplete() {
        #expect(Self.macroCases.count == 34)
        #expect(Self.editingCases.count == 32)
        #expect(!Self.macroTable.isEmpty)
        for cases in [Self.macroCases, Self.editingCases] {
            #expect(Set(cases.map(\.id)).count == cases.count, "duplicate ids")
        }
    }

    @Test(arguments: macroCases)
    func macros(_ corpusCase: QACorpusCase) throws {
        try check(corpusCase)
    }

    @Test(arguments: editingCases)
    func editing(_ corpusCase: QACorpusCase) throws {
        try check(corpusCase)
    }

    private func check(_ corpusCase: QACorpusCase) throws {
        let (text, restore) = try QACorpus.run(corpusCase, macros: Self.macroTable)
        #expect(text == corpusCase.expected, "\(corpusCase): \(corpusCase.note)")
        if let expectedRestore = corpusCase.expectedRestore {
            #expect(restore == expectedRestore, "\(corpusCase) restore: \(corpusCase.note)")
        }
    }
}
