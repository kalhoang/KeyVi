// SPDX-License-Identifier: MPL-2.0
//
// lexicon-builder, driven as a subprocess: reproducible build (ENG-R810), the CI check, the tokeniser,
// the prose corpus (ENG-T20) and the ambiguity-candidate plumbing (ENG-R820) with a fake engine.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData

@Suite(.serialized)
struct LexiconBuilderTests {
    // MARK: Reproducibility (ENG-R810)

    @Test func buildTwiceGivesIdenticalBytesEqualToTheCommittedResources() throws {
        let first = try TempDirectory.make("build-a")
        let second = try TempDirectory.make("build-b")
        defer {
            TempDirectory.remove(first)
            TempDirectory.remove(second)
        }
        for output in [first, second] {
            let result = try Builder.run(["build", "--output", output.path])
            #expect(result.status == 0, "build failed: \(result.errors)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("Resources").path)
            .sorted()
        #expect(
            names == [
                "NOTICES.txt", "ambiguity.tsv", "attested.txt", "english.txt", "manifest.json", "tech-always.txt",
                "tech-code-only.txt",
            ])
        for name in names {
            let a = try Data(contentsOf: first.appendingPathComponent("Resources/\(name)"))
            let b = try Data(contentsOf: second.appendingPathComponent("Resources/\(name)"))
            let committed = try Data(contentsOf: TestPaths.committedResources.appendingPathComponent(name))
            #expect(a == b, "\(name) differs between two builds")
            #expect(a == committed, "\(name) differs from the committed resource; run lexicon-builder build")
        }
        let derivedA = try Data(contentsOf: first.appendingPathComponent("derived/attested-candidates.tsv"))
        let derivedB = try Data(contentsOf: second.appendingPathComponent("derived/attested-candidates.tsv"))
        #expect(derivedA == derivedB)
        // The freshly built directory loads through the public loader.
        let resources = try Resources.load(
            from: first.appendingPathComponent("Resources"), userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        #expect(resources.english.contains("keyboard"))
    }

    @Test func checkPassesOnTheCommittedOutputs() throws {
        let result = try Builder.run(["check"])
        #expect(result.status == 0, "check failed: \(result.errors)")
        #expect(result.text.contains("check passed"))
    }

    @Test func buildRefusesUnpinnedInputs() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        #expect(try Builder.run(["pin", "--data-root", root.appendingPathComponent("data").path]).status == 0)
        let resources = root.appendingPathComponent("out")
        let ok = try Builder.run([
            "build", "--data-root", root.appendingPathComponent("data").path, "--output", resources.path,
        ])
        #expect(ok.status == 0, "\(ok.errors)")
        let loaded = try Resources.load(
            from: resources.appendingPathComponent("Resources"), userKeepRaw: WordSet([]),
            userKeepVietnamese: WordSet([]))
        #expect(loaded.english.contains("test"))
        #expect(!loaded.english.contains("don"), "entries with apostrophes are dropped")
        #expect(loaded.attestedSyllables.contains("thủy") && loaded.attestedSyllables.contains("thuỷ"))
        #expect(loaded.ambiguity["test"] == .english)
        try write("www\nwifi\nnew\n", to: root.appendingPathComponent("data/inputs/tech-always.txt"))
        let refused = try Builder.run([
            "build", "--data-root", root.appendingPathComponent("data").path, "--output", resources.path,
        ])
        #expect(refused.status != 0)
        #expect(refused.errors.contains("changed: inputs/tech-always.txt"))
    }

    // MARK: Tokeniser

    @Test func tokeniserKeepsOnlyVietnameseLetterRuns() throws {
        let input =
            "Điều 15. Văn bản quy phạm pháp luật (hoà-bình), THUỶ 2026; fax, Internet, ĐHQG, M'Đrắk, cafe\u{0301}\n"
        let tokens = try Builder.run(["tokenize"], input: input)
        #expect(tokens.status == 0)
        #expect(
            tokens.text.split(separator: "\n") == [
                "điều", "văn", "bản", "quy", "phạm", "pháp", "luật", "hoà", "bình", "thuỷ", "internet", "đhqg", "m",
                "đrắk",
            ])
        let prose = try Builder.run(["tokenize", "--prose"], input: "Bộ luật NÀY, fax 3 lần")
        #expect(prose.text.split(separator: "\n") == ["Bộ", "luật", "NÀY", "lần"])
    }

    // MARK: Prose corpus (ENG-T20)

    @Test func proseCorpusHasAtLeast200000SyllablesAndIsReproducible() throws {
        let text = try String(
            contentsOf: TestPaths.dataRoot.appendingPathComponent("corpus/prose-vi.txt"), encoding: .utf8)
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        let tokens = body.reduce(0) { $0 + $1.split(separator: " ").count }
        #expect(tokens >= 200_000)
        #expect(text.contains("# Tokens: \(tokens)\n"))
        let output = try TempDirectory.make("prose")
        defer { TempDirectory.remove(output) }
        let file = output.appendingPathComponent("prose.txt")
        let result = try Builder.run(["prose-corpus", "--output", file.path])
        #expect(result.status == 0, "\(result.errors)")
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }

    // MARK: Ambiguity candidates (ENG-R820)

    @Test func ambiguityCandidatesPlumbingWithAFakeEngine() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let data = root.appendingPathComponent("data")
        let resources = root.appendingPathComponent("resources")
        // Attested displays: á, tét, tả, thêm. The fake engine decides displays and validity.
        try write("á\ntét\ntả\nthêm\n", to: resources.appendingPathComponent("attested.txt"))
        try write("token\tcount\ná\t5\ntả\t2\n", to: data.appendingPathComponent("derived/attested-candidates.tsv"))
        let fake = root.appendingPathComponent("fake.tsv")
        try write(
            """
            as\tá\tá\tstandard
            is\tí\tí\tstandard
            test\ttét\ttét\tstandard
            theme\tthêm\tthêm\textended
            the\tthe\tthe\tstandard
            tar\ttả\ttả\tstandard
            www\tww\tww\tinvalid

            """, to: fake)
        let output = root.appendingPathComponent("candidates.tsv")
        let arguments = [
            "ambiguity-candidates", "--data-root", data.path, "--resources", resources.path, "--fake-engine", fake.path,
            "--output", output.path,
        ]
        let result = try Builder.run(arguments)
        #expect(result.status == 0, "\(result.errors)")
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "raw\ttraditional\tmodern\tsource\tcorpus_count\tcurrent_row",
                "as\tá\tá\tscowl-10\t5\tvi/proposed",
                "test\ttét\ttét\tscowl-10\t0\ten/proposed",
                "tar\ttả\ttả\ttech-code-only\t2\t-",
            ])
        // --merge appends the candidate without a row as vi/unreviewed (ENG-R821).
        let merged = try Builder.run(arguments + ["--merge"])
        #expect(merged.status == 0, "\(merged.errors)")
        let table = try String(contentsOf: data.appendingPathComponent("inputs/ambiguity.tsv"), encoding: .utf8)
        #expect(table.hasSuffix("tar\tvi\tunreviewed\ttả\tgenerated candidate (tech-code-only, corpus count 2)\n"))
    }

    @Test func ambiguityCandidatesRunAgainstTheRealEngine() throws {
        // Produces candidates only once the engine track's composition and validator are merged; until
        // then the stub passes every key through and the list is empty. The command must still succeed.
        let output = try TempDirectory.make("candidates")
        defer { TempDirectory.remove(output) }
        let result = try Builder.run(["ambiguity-candidates", "--output", output.appendingPathComponent("c.tsv").path])
        #expect(result.status == 0, "\(result.errors)")
        let text = try String(contentsOf: output.appendingPathComponent("c.tsv"), encoding: .utf8)
        #expect(text.hasPrefix("raw\ttraditional\tmodern\tsource\tcorpus_count\tcurrent_row\n"))
    }

    @Test func unknownCommandFails() throws {
        let result = try Builder.run(["frobnicate"])
        #expect(result.status != 0)
        #expect(result.errors.contains("unknown command"))
    }
}

/// A tiny but complete data/ tree for builder tests that must not touch the real inputs.
enum MiniDataRoot {
    static func make() throws -> URL {
        let root = try TempDirectory.make("mini")
        let data = root.appendingPathComponent("data")
        let scowl = data.appendingPathComponent("inputs/english/scowl-2020.12.07")
        for category in ["english", "american", "british", "british_z"] {
            for level in [10, 20, 35] {
                try write("", to: scowl.appendingPathComponent("\(category)-words.\(level)"))
            }
        }
        try write("as\nis\ntest\nthe\nI\ndon't\n", to: scowl.appendingPathComponent("english-words.10"))
        try write("theme\n", to: scowl.appendingPathComponent("english-words.35"))
        try write("color\n", to: scowl.appendingPathComponent("american-words.20"))
        try write("# tech\nwww\nwifi\n", to: data.appendingPathComponent("inputs/tech-always.txt"))
        try write("tar\n", to: data.appendingPathComponent("inputs/tech-code-only.txt"))
        try write(
            "# additions\nthủy\tfixture\ná\tfixture\n", to: data.appendingPathComponent("inputs/attested-additions.txt")
        )
        try write(
            "raw\tdecision\tstatus\tdisplay\tnote\nas\tvi\tproposed\tá\tfixture\ntest\ten\tproposed\ttét\tfixture\n",
            to: data.appendingPathComponent("inputs/ambiguity.tsv"))
        let header = "id\tfile\turl\tsha256\tbytes\tretrieved\ttitle\tnumber\tissued\tissuer\tpage\n"
        let row =
            "law\tlegal/law.doc\thttps://example.invalid/law.doc\t\(String(repeating: "0", count: 64))\t0\t2026-11-13\tLuật\t1/2026/QH15\t2026-01-01\tQuốc hội\thttps://example.invalid\n"
        try write(header + row, to: data.appendingPathComponent("inputs/legal/SOURCES.tsv"))
        try write("Điều 1. Luật này quy định về thủy lợi.\n", to: data.appendingPathComponent("inputs/legal/law.txt"))
        try write("Notices\n@include extra.txt\n", to: data.appendingPathComponent("licenses/bundled-notices.txt"))
        try write("Extra notice\n", to: data.appendingPathComponent("licenses/extra.txt"))
        try write("", to: data.appendingPathComponent("inputs/MANIFEST.sha256"))
        return root
    }
}
