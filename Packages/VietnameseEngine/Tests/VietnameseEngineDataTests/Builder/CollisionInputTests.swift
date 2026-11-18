// SPDX-License-Identifier: MPL-2.0
//
// The collision inputs of lexicon-builder (spec/01-engine.md 8.2, ENG-R825 to ENG-R828, ENG-R863): parsers,
// the build checks (no phrase whose Vietnamese reading is in the prose corpus, supplement words that type as
// their attested display and are not English) and the product owner's list decisions of 15/11/2026 in the
// committed inputs.

import Foundation
import Testing
import VietnameseEngine

@testable import lexicon_builder

@Suite("Collision inputs of lexicon-builder")
struct CollisionInputTests {
    private func file(_ text: String, named name: String = "list.txt") throws -> (URL, URL) {
        let directory = try TempDirectory.make("collision-inputs")
        let url = directory.appendingPathComponent(name)
        try write(text, to: url)
        return (directory, url)
    }

    @Test("Word lists: one lowercase word a-z per line, unique, comments allowed")
    func wordLists() throws {
        let (directory, url) = try file("# header\nthe\nam # trailing comment\n\nbe\n")
        defer { TempDirectory.remove(directory) }
        #expect(try CollisionList.words(url) == ["am", "be", "the"])
        for bad in ["The\n", "two words\n", "the\nthe\n", "đi\n", "a1\n"] {
            try write(bad, to: url)
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try CollisionList.words(url) }
        }
    }

    @Test("ENG-R826 phrases: 2 to 4 lowercase words separated by one space, unique")
    func phrases() throws {
        let (directory, url) = try file("# phrases\nsuch as\nas soon as\nbeen there done that\n")
        defer { TempDirectory.remove(directory) }
        #expect(try CollisionList.phrases(url) == ["as soon as", "been there done that", "such as"])
        for bad in ["single\n", "a b c d e\n", "such  as\n", "Such as\n", "such as\nsuch as\n", "such-as\n"] {
            try write(bad, to: url)
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try CollisionList.phrases(url) }
        }
    }

    @Test("ENG-R863 supplement and ENG-R828 tail words: two tab-separated columns")
    func twoColumnLists() throws {
        let (directory, url) = try file("# supplement\ngif\tgì\ncos\tcó\n")
        defer { TempDirectory.remove(directory) }
        let supplement = try CollisionList.supplement(url)
        #expect(supplement.map(\.raw) == ["cos", "gif"] && supplement.map(\.display) == ["có", "gì"])
        for bad in ["gif\n", "Gif\tgì\n", "gif\tGì\n", "gif\tgì\ngif\tgì\n", "gif\tgi\u{0300}\n"] {
            try write(bad, to: url)
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try CollisionList.supplement(url) }
        }
        try write("# tail\nrồi\tword\nnha\tparticle\n", to: url)
        let tail = try CollisionList.tailWords(url)
        #expect(tail.map(\.word) == ["nha", "rồi"] && tail.map(\.isParticle) == [true, false])
        for bad in ["nha\n", "nha\tadverb\n", "Nha\tparticle\n", "nha\tparticle\nnha\tword\n"] {
            try write(bad, to: url)
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try CollisionList.tailWords(url) }
        }
    }

    @Test("ENG-R826 the build fails when a phrase's Vietnamese reading occurs in the prose corpus")
    func phraseReadingInTheProseCorpus() throws {
        let corpus = "# header\nLuật này quy định về thủy lợi\nCó thể\n"
        let typer = EngineTyper()
        // `thuyr loiwj` reads `thủy lợi`, a sequence of the corpus: planted, so the check must fail.
        #expect(throws: BuilderError.self) {
            try CollisionChecks.checkPhrases(["such as", "thuyr loiwj"], corpus: corpus, typer: typer)
        }
        // Readings across a paragraph break, or with a word that differs, do not count.
        try CollisionChecks.checkPhrases(["loiwj cos", "thuyr looij"], corpus: corpus, typer: typer)
        // A phrase whose words all stay as typed has no Vietnamese reading.
        try CollisionChecks.checkPhrases(["quy dinh"], corpus: "quy dinh\n", typer: typer)
        do {
            try CollisionChecks.checkPhrases(["thuyr loiwj"], corpus: corpus, typer: typer)
        } catch let error as BuilderError {
            #expect(error.description.contains("thuyr loiwj (thủy lợi)"))
        }
    }

    @Test("ENG-R863 supplement words type as their attested display and are not English")
    func supplementChecks() throws {
        let typer = EngineTyper()
        let attested: Set<String> = ["có", "gì"]
        try CollisionChecks.checkSupplement(
            [("cos", "có"), ("gif", "gì")], english: ["test": 10], techAlways: [], attested: attested, typer: typer)
        let cases: [[(raw: String, display: String)]] = [
            [("cos", "cố")],  // the engine types `có`
            [("test", "tét")],  // English: an ambiguity row instead
            [("nos", "nó")],  // not attested here
        ]
        for rows in cases {
            #expect(throws: BuilderError.self, "\(rows)") {
                try CollisionChecks.checkSupplement(
                    rows, english: ["test": 10], techAlways: ["wifi"], attested: attested, typer: typer)
            }
        }
    }

    @Test("ENG-R826 Builder.build refuses a planted phrase when data/corpus/prose-vi.txt holds its reading")
    func buildRefusesAPlantedPhrase() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let data = root.appendingPathComponent("data")
        let layout = Layout(dataRoot: data, resources: root.appendingPathComponent("out"))
        try write("# corpus\nĐiều Luật này quy định về thủy lợi\n", to: layout.corpusFile)
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        _ = try Builder.build(layout)
        try write("such as\nthuyr loiwj\n", to: data.appendingPathComponent("inputs/phrases.txt"))
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        #expect(throws: BuilderError.self) { try Builder.build(layout) }
        // The supplement check runs in the same build.
        try write("such as\n", to: data.appendingPathComponent("inputs/phrases.txt"))
        try write("thuyr\tthùy\n", to: data.appendingPathComponent("inputs/collision-supplement.txt"))
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        #expect(throws: BuilderError.self) { try Builder.build(layout) }
    }

    @Test("Decisions of 15/11/2026 in the committed inputs: `as` only, no `as of`, no tech words in run vi")
    func productOwnerListDecisions() throws {
        let layout = Layout(dataRoot: TestPaths.dataRoot, resources: TestPaths.committedResources)
        let inputs = try CollisionInputs.load(layout)
        #expect(inputs.boundaryParticles == ["as"])
        for excluded in ["as of", "its own", "has to", "how to"] { #expect(!inputs.phrases.contains(excluded)) }
        #expect(inputs.phrases.contains("as hell") && inputs.phrases.contains("such as"))
        // Added by the product owner on 18/11/2026: English context for the doubled `off` and `mess` (ENG-R804).
        for added in ["day off", "sale off", "a mess"] { #expect(inputs.phrases.contains(added)) }
        // Parked for a later decision of the product owner (18/11/2026).
        for parked in ["mess up", "off topic", "off the record"] { #expect(!inputs.phrases.contains(parked)) }
        #expect(inputs.phrases.count == 330)
        #expect(inputs.supplement.count == 34 && inputs.supplement.contains { $0.raw == "cos" && $0.display == "có" })
        #expect(inputs.englishLean == ["am", "be", "by", "he", "i", "me", "my", "she", "the", "them", "then", "we"])
        #expect(inputs.tailWords.filter(\.isParticle).count == 31 && inputs.tailWords.count == 63)
        let rows = try AmbiguityRow.load(layout.inputs.appendingPathComponent("ambiguity.tsv"))
        let runVi = Set(rows.filter { $0.run == .vi }.map(\.raw))
        for dropped in ["rust", "testers", "visa", "tee"] { #expect(!runVi.contains(dropped)) }
        #expect(runVi.contains("tows") && runVi.contains("seeps") && runVi.count == 53)
        let kinds = Dictionary(uniqueKeysWithValues: rows.map { ($0.raw, $0.viKind) })
        #expect(kinds["as"] == .particle && kinds["been"] == .function && kinds["test"] == .content)
    }
}
