// SPDX-License-Identifier: MPL-2.0
//
// What the real-data gates of spec/01-engine.md 8.8 share: the bundled resources (`Resources.bundled`,
// loaded once), the committed word lists, the ENG-T11 exception list and the ENG-T20 prose corpus. The
// corpus and the exception list are read from the repository checkout (`TestPaths`), which is where
// `swift test` runs locally and in CI, so nothing is copied and `lexicon-builder check` keeps guarding the
// one corpus file.

import Foundation
import VietnameseEngine
import VietnameseEngineData

enum RealData {
    private static let loaded = Result { () throws -> Resources in
        try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
    }

    /// The bundled resources with empty user lists and no macros.
    static func resources() throws -> Resources { try loaded.get() }

    /// ENG-T10's word list: the English lexicon plus both tech lists, unique, in byte order.
    static func englishCorpusWords() throws -> [String] {
        var words = Set<String>()
        for name in ["english.txt", "tech-always.txt", "tech-code-only.txt"] {
            words.formUnion(try lines(TestPaths.committedResources.appendingPathComponent(name)))
        }
        return words.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// The bundled code-only tech list (8.2), in file order.
    static func codeOnlyWords() throws -> [String] {
        try lines(TestPaths.committedResources.appendingPathComponent("tech-code-only.txt"))
    }

    /// `known-exceptions.txt` of the engine tests (ENG-T11), shared with the fixture run of ENG-T10.
    static var knownExceptionsFile: URL {
        TestPaths.packageRoot.appendingPathComponent("Tests/VietnameseEngineTests/Corpus/known-exceptions.txt")
    }

    /// The ENG-T20 corpus without its `#` header lines, one paragraph per line.
    static func proseCorpus() throws -> String {
        let url = TestPaths.dataRoot.appendingPathComponent("corpus/prose-vi.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n") + "\n"
    }

    private static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// One line per item, for test output.
    static func listing<S: Sequence>(_ items: S) -> String where S.Element: CustomStringConvertible {
        items.map { "  \($0)" }.joined(separator: "\n")
    }
}
