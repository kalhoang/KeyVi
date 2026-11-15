// SPDX-License-Identifier: MPL-2.0
//
// lexicon-builder, driven as a subprocess: reproducible build (ENG-R810), the CI check, the tokeniser,
// the prose corpus (ENG-T20) and the ambiguity-candidate plumbing (ENG-R820) with a fake engine.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData

@testable import lexicon_builder

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
            let result = try BuilderProcess.run(["build", "--output", output.path])
            #expect(result.status == 0, "build failed: \(result.errors)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("Resources").path)
            .sorted()
        #expect(
            names == [
                "NOTICES.txt", "ambiguity.tsv", "attested.txt", "boundary-particles.txt", "collision-supplement.txt",
                "english-function-words.txt", "english-lean-neutral.txt", "english-pre-guard.txt", "english.txt",
                "manifest.json", "phrases.txt", "tech-always.txt", "tech-code-only.txt", "vi-tail-particles.txt",
                "vi-tail-words.txt",
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
        let result = try BuilderProcess.run(["check"])
        #expect(result.status == 0, "check failed: \(result.errors)")
        #expect(result.text.contains("check passed"))
    }

    @Test func buildRefusesUnpinnedInputs() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        #expect(try BuilderProcess.run(["pin", "--data-root", root.appendingPathComponent("data").path]).status == 0)
        let resources = root.appendingPathComponent("out")
        let ok = try BuilderProcess.run([
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
        // The collision lists of the fixture (ENG-R825 to ENG-R828).
        #expect(loaded.collision.supplement.contains("thuyr"))
        #expect(loaded.collision.phrases.count == 1)
        #expect(loaded.collision.tailParticles.contains("nha") && loaded.collision.tailWords.contains("rồi"))
        #expect(loaded.collision.runExempt.contains("as") && loaded.collision.readingKinds["as"] == .particle)
        try write("www\nwifi\nnew\n", to: root.appendingPathComponent("data/inputs/tech-always.txt"))
        let refused = try BuilderProcess.run([
            "build", "--data-root", root.appendingPathComponent("data").path, "--output", resources.path,
        ])
        #expect(refused.status != 0)
        #expect(refused.errors.contains("changed: inputs/tech-always.txt"))
    }

    // MARK: Tokeniser

    @Test func tokeniserKeepsOnlyVietnameseLetterRuns() throws {
        let input =
            "Điều 15. Văn bản quy phạm pháp luật (hoà-bình), THUỶ 2026; fax, Internet, ĐHQG, M'Đrắk, cafe\u{0301}\n"
        let tokens = try BuilderProcess.run(["tokenize"], input: input)
        #expect(tokens.status == 0)
        #expect(
            tokens.text.split(separator: "\n") == [
                "điều", "văn", "bản", "quy", "phạm", "pháp", "luật", "hoà", "bình", "thuỷ", "internet", "đhqg", "m",
                "đrắk",
            ])
        let prose = try BuilderProcess.run(["tokenize", "--prose"], input: "Bộ luật NÀY, fax 3 lần")
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
        let result = try BuilderProcess.run(["prose-corpus", "--output", file.path])
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
        let result = try BuilderProcess.run(arguments)
        #expect(result.status == 0, "\(result.errors)")
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "raw\tmethod\ttraditional\tmodern\tattested\tsource\tcorpus_count\tmerge_as\tcurrent_row",
                "as\ttelex\tá\tá\tyes\tscowl-10\t5\tvi/unreviewed\tvi/proposed",
                "is\ttelex\tí\tí\tno\tscowl-10\t0\ten/proposed\t-",
                "test\ttelex\ttét\ttét\tyes\tscowl-10\t0\tvi/unreviewed\ten/proposed",
                "tar\ttelex\ttả\ttả\tyes\ttech-code-only\t2\tvi/unreviewed\t-",
            ])
        // --merge adds the candidates without a row (ENG-R821): `tar` (code-only, attested) as vi/unreviewed,
        // `is` (display not attested, restored by L8) as en/proposed in the generated block at the end.
        let merged = try BuilderProcess.run(arguments + ["--merge"])
        #expect(merged.status == 0, "\(merged.errors)")
        let table = try String(contentsOf: data.appendingPathComponent("inputs/ambiguity.tsv"), encoding: .utf8)
        let tar = try #require(
            table.range(
                of: "\ntar\tvi\tunreviewed\ttả\ten\tcontent\tgenerated candidate (tech-code-only, corpus count 2)\n"))
        let block = try #require(table.range(of: "\n\(AmbiguityCandidates.generatedBlockMarker)"))
        let generated = try #require(table.range(of: "\nis\ten\tproposed\tí\t"))
        #expect(tar.lowerBound < block.lowerBound && block.lowerBound < generated.lowerBound)
        #expect(table.hasSuffix("\(AmbiguityRow.GeneratedReason.unattested.rawValue)\n"))
    }

    @Test func ambiguityCandidatesRunAgainstTheRealEngine() throws {
        let output = try TempDirectory.make("candidates")
        defer { TempDirectory.remove(output) }
        let result = try BuilderProcess.run([
            "ambiguity-candidates", "--output", output.appendingPathComponent("c.tsv").path,
        ])
        #expect(result.status == 0, "\(result.errors)")
        let text = try String(contentsOf: output.appendingPathComponent("c.tsv"), encoding: .utf8)
        #expect(text.hasPrefix(AmbiguityCandidateHeader.text + "\n"))
        let rows = text.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        let byRaw = Dictionary(rows.dropFirst().map { ($0[0], $0) }, uniquingKeysWith: { first, _ in first })
        // ENG-R821 proposals and spec 8.3 examples are candidates with the real engine and data.
        #expect(byRaw["there"]?[2] == "thể")
        #expect(byRaw["as"]?[4] == "yes")
        #expect(byRaw["test"]?[8] == "en/proposed")
        // ENG-R874: the paper size a4 changes only in VNI (ã).
        #expect(byRaw["a4"]?[1] == "vni")
        // Every English word whose Telex display is an unattested Tier A syllable is listed (rule L8).
        #expect(rows.dropFirst().contains { $0[4] == "no" })
    }

    @Test func unknownCommandFails() throws {
        let result = try BuilderProcess.run(["frobnicate"])
        #expect(result.status != 0)
        #expect(result.errors.contains("unknown command"))
    }
}

/// The header of `data/derived/ambiguity-candidates.tsv`.
enum AmbiguityCandidateHeader {
    static let text = "raw\tmethod\ttraditional\tmodern\tattested\tsource\tcorpus_count\tmerge_as\tcurrent_row"
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
            "raw\tdecision\tstatus\tdisplay\trun\tviKind\tnote\nas\tvi\tproposed\tá\tvi\tparticle\tfixture\n"
                + "test\ten\tproposed\ttét\ten\tcontent\tfixture\n",
            to: data.appendingPathComponent("inputs/ambiguity.tsv"))
        // The collision lists (ENG-R825 to ENG-R828, ENG-R863).
        let inputs = data.appendingPathComponent("inputs")
        try write("# phrases\nsuch as\n", to: inputs.appendingPathComponent("phrases.txt"))
        try write("# supplement\nthuyr\tthủy\n", to: inputs.appendingPathComponent("collision-supplement.txt"))
        try write("as\n", to: inputs.appendingPathComponent("boundary-particles.txt"))
        try write("is\nthe\n", to: inputs.appendingPathComponent("english-function-words.txt"))
        try write("the\n", to: inputs.appendingPathComponent("english-lean-neutral.txt"))
        try write("nha\tparticle\nrồi\tword\n", to: inputs.appendingPathComponent("vi-tail-words.txt"))
        try write("the\n", to: inputs.appendingPathComponent("english-pre-guard.txt"))
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
