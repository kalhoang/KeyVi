// SPDX-License-Identifier: MPL-2.0
//
// In-process unit tests of lexicon-builder (`@testable import lexicon_builder`): option parsing, input
// parsers and their error messages, text utilities, the portable SHA-256, the generated file formats and
// the input manifest (ENG-R810). The CLI end to end stays in LexiconBuilderTests.

import CryptoKit
import Foundation
import Testing
import VietnameseEngine

@testable import lexicon_builder

@Suite struct BuilderUnitTests {
    // MARK: Options and layout

    @Test func optionsSeparatePositionalsValuesAndFlags() throws {
        let options = try Options(["build", "--output", "out", "--merge", "extra", "--min-tokens", "12"])
        #expect(options.positional == ["build", "extra"])
        #expect(options.values == ["--output": "out", "--min-tokens": "12"])
        #expect(options.flags == ["--merge"])
        #expect(try options.integer("--min-tokens") == 12)
        #expect(try options.integer("--data-root") == nil)
    }

    @Test func optionsRejectUnknownOptionsMissingValuesAndBadIntegers() throws {
        #expect(throws: BuilderError.self) { try Options(["--frobnicate"]) }
        #expect(throws: BuilderError.self) { try Options(["build", "--output"]) }
        #expect(throws: BuilderError.self) { try Options(["--min-tokens", "0"]).integer("--min-tokens") }
        #expect(throws: BuilderError.self) { try Options(["--min-tokens", "x"]).integer("--min-tokens") }
    }

    @Test func layoutFindsTheDataRootAboveTheWorkingDirectory() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let found = try #require(Layout.locateDataRoot(from: nested))
        #expect(found.standardizedFileURL.path.hasSuffix("/data"))
        #expect(Layout.locateDataRoot(from: URL(fileURLWithPath: "/")) == nil)
        let options = try Options(["--data-root", root.appendingPathComponent("data").path])
        let layout = try options.layout()
        #expect(layout.resources.path.hasSuffix(Layout.defaultResourcesPath))
        #expect(layout.corpusFile.lastPathComponent == "prose-vi.txt")
    }

    // MARK: English lexicon

    @Test func englishLexiconKeepsLowercaseLettersWithTheSmallestLevel() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let scowl = root.appendingPathComponent("data/inputs/english/scowl-2020.12.07")
        try write("Test\ncafé\nx-ray\n", to: scowl.appendingPathComponent("british-words.35"))
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        let words = try EnglishLexicon.load(layout)
        #expect(words["test"] == 10, "the smallest level wins")
        #expect(words["theme"] == 35)
        #expect(words["color"] == 20)
        #expect(words["café"] == nil && words["x-ray"] == nil && words["don't"] == nil)
    }

    @Test func englishLexiconDropsOneLetterEntriesOtherThanAAndI() throws {
        // SCOWL lists letters such as `m`; Vietnamese text uses lone consonants as list markers (`m)`) and
        // chat abbreviations (`m` for mày), and ENG-R823 would make each of them an English token that
        // turns the run English (docs/decisions/0202).
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let scowl = root.appendingPathComponent("data/inputs/english/scowl-2020.12.07")
        try write("a\nm\nx\nok\n", to: scowl.appendingPathComponent("english-words.20"))
        let words = try EnglishLexicon.load(Layout(dataRoot: root.appendingPathComponent("data"), resources: root))
        #expect(words["a"] == 20)
        #expect(words["i"] == 10)
        #expect(words["ok"] == 20)
        #expect(words["m"] == nil)
        #expect(words["x"] == nil)
    }

    // MARK: SCOWL members: the lexicon and the guard list (ENG-R1120)

    /// ENG-R1120: the guard list reads the SCOWL "words" lists of sizes 40 to 70 and the "proper-names" lists of sizes
    /// 10 to 70 of the four components. The pinned archive holds no proper-names list at 10, 20 or 55, none for
    /// `british` or `british_z` at or below 70, and `american` only at 50, so the spec's sources are these 26 members
    /// (docs/decisions/0203-correction-data.md).
    @Test func guardListFilesAreTheTwentySixMembersOfThePinnedArchive() {
        let words = ["english", "american", "british", "british_z"].flatMap { category in
            [40, 50, 55, 60, 70].map { "\(category)-words.\($0)" }
        }
        let names = [
            "english-proper-names.35", "english-proper-names.40", "english-proper-names.50", "english-proper-names.60",
            "english-proper-names.70", "american-proper-names.50",
        ]
        #expect(Scowl.guardListFiles == words + names)
        #expect(Scowl.guardListFiles.count == 26)
        #expect(Set(Scowl.guardListFiles).isDisjoint(with: Scowl.componentFiles))
    }

    @Test func lexiconComponentFilesAreUnchanged() {
        #expect(
            Scowl.componentFiles == [
                "english-words.10", "english-words.20", "english-words.35", "american-words.10", "american-words.20",
                "american-words.35", "british-words.10", "british-words.20", "british-words.35", "british_z-words.10",
                "british_z-words.20", "british_z-words.35",
            ])
    }

    /// The English lexicon (8.2) stays at levels 10, 20 and 35 of the `words` lists when the guard list's members sit
    /// next to them in the same directory.
    @Test func englishLexiconReadsNoGuardListMember() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        let before = try EnglishLexicon.load(layout)
        try write("zebra\nquixotic\n", to: layout.scowlDirectory.appendingPathComponent("english-words.40"))
        try write("Biden\n", to: layout.scowlDirectory.appendingPathComponent("english-proper-names.50"))
        #expect(try EnglishLexicon.load(layout) == before)
    }

    /// `import scowl` extracts the guard list's members with the lexicon's, and a member missing from the archive is
    /// fatal: a list dropped by mistake must not pass unnoticed (ENG-R810, ENG-R1120).
    @Test func importArchiveExtractsTheGuardMembersAndFailsWithoutOne() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        try ScowlArchiveFixture.install(in: layout, omitting: nil)
        try Scowl.importArchive(layout)
        for file in Scowl.componentFiles + Scowl.guardListFiles {
            let text = try String(
                contentsOf: layout.scowlDirectory.appendingPathComponent(file), encoding: .isoLatin1)
            #expect(text == "\(file)\n", "\(file)")
        }
        #expect(FileManager.default.fileExists(atPath: layout.licenses.appendingPathComponent(Scowl.licenseFile).path))

        try ScowlArchiveFixture.install(in: layout, omitting: "english-proper-names.70")
        do {
            try Scowl.importArchive(layout)
            Issue.record("an archive without english-proper-names.70 was imported")
        } catch let error as BuilderError {
            #expect(error.description.contains("english-proper-names.70"))
        }
    }

    // MARK: Hand-edited inputs

    @Test func techListValidatesEntries() throws {
        let directory = try TempDirectory.make("tech")
        defer { TempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("tech.txt")
        try write("# comment\nmp3   # trailing comment\n\nwifi\n", to: file)
        #expect(try TechList.load(file) == ["mp3", "wifi"])
        #expect(TechList.isValidEntry("4g") && !TechList.isValidEntry("42") && !TechList.isValidEntry("Wifi"))
        #expect(!TechList.isValidEntry("") && !TechList.isValidEntry("a-b"))
        try write("wifi\nwifi\n", to: file)
        #expect(throws: BuilderError.self) { try TechList.load(file) }
        try write("WiFi\n", to: file)
        #expect(throws: BuilderError.self) { try TechList.load(file) }
    }

    @Test func attestedAdditionsNeedAReasonAndLowercaseNFCLetters() throws {
        let directory = try TempDirectory.make("additions")
        defer { TempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("attested-additions.txt")
        try write("# header\n\nthủy\treason one\ná\treason two\n", to: file)
        #expect(try AttestedAdditions.load(file) == ["thủy", "á"])
        for bad in ["thủy\n", "thủy\t \n", "Thủy\tx\n", "thu\u{0309}y\tx\n", "fax\tx\n", "á\tx\ná\ty\n"] {
            try write(bad, to: file)
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try AttestedAdditions.load(file) }
        }
    }

    @Test func ambiguityRowsParseAndRejectMalformedLines() throws {
        let row = try AmbiguityRow.parse("as\tvi\tproposed\tá\tvi\tparticle\tnote", number: 1)
        #expect(
            row
                == AmbiguityRow(
                    raw: "as", decision: .vi, status: .proposed, display: "á", run: .vi, viKind: .particle, note: "note"
                ))
        #expect(row.line == "as\tvi\tproposed\tá\tvi\tparticle\tnote")
        // ENG-R827: new rows default to run en, viKind content.
        #expect(
            AmbiguityRow(raw: "x", decision: .vi, status: .unreviewed, display: "x", note: "").line
                == "x\tvi\tunreviewed\tx\ten\tcontent\t")
        for bad in [
            "as\tvi\tproposed\tá\ten\tcontent", "As\tvi\tproposed\tá\ten\tcontent\tx",
            "as\tmaybe\tproposed\tá\ten\tcontent\tx", "as\tvi\tlater\tá\ten\tcontent\tx",
            "as\tvi\tproposed\ta\u{0301}\ten\tcontent\tx", "as\tvi\tproposed\tá\tboth\tcontent\tx",
            "as\tvi\tproposed\tá\ten\tnoun\tx", "as\tvi\tproposed\tá\tx",
        ] {
            #expect(throws: BuilderError.self, "\(bad.debugDescription)") { try AmbiguityRow.parse(bad, number: 3) }
        }
        let directory = try TempDirectory.make("ambiguity")
        defer { TempDirectory.remove(directory) }
        let file = directory.appendingPathComponent("ambiguity.tsv")
        try write("as\tvi\tproposed\tá\ten\tcontent\tx\n", to: file)
        #expect(throws: BuilderError.self, "the header comes first") { try AmbiguityRow.load(file) }
        try write(
            "\(AmbiguityRow.header)\nas\tvi\tproposed\tá\ten\tcontent\tx\nas\ten\tproposed\tá\ten\tcontent\ty\n",
            to: file)
        #expect(throws: BuilderError.self, "duplicate raw keys") { try AmbiguityRow.load(file) }
    }

    @Test func fileHelpersSplitCommentsAndBlankLines() {
        let text = "one # c\n\n  two  \n# only comment\nthree"
        #expect(FileIO.contentLines(text).map(\.text) == ["one", "two", "three"])
        #expect(FileIO.contentLines(text).map(\.number) == [1, 3, 5])
        #expect(FileIO.dataLines("a\tb\n\n# x\nc").map(\.text) == ["a\tb", "c"])
        #expect(joinedLines([]) == "" && joinedLines(["a", "b"]) == "a\nb\n")
        #expect(utf8Sorted(["b", "á", "a", "Z"]) == ["Z", "a", "b", "á"])
    }

    // MARK: Text utilities

    @Test func vietnameseTextTokenisesAndConvertsToneStyles() {
        #expect(VietnameseText.syllableTokens("Điều 15: HOÀ-bình, fax") == ["điều", "hoà", "bình"])
        #expect(VietnameseText.proseTokens("Bộ LUẬT 2015 wifi") == ["Bộ", "LUẬT"])
        #expect(!VietnameseText.isVietnameseLetter("f") && VietnameseText.isVietnameseLetter("ạ"))
        #expect(VietnameseText.otherToneStyle(of: "hòa") == "hoà")
        #expect(VietnameseText.otherToneStyle(of: "hoà") == "hòa")
        #expect(VietnameseText.otherToneStyle(of: "khỏe") == "khoẻ")
        #expect(VietnameseText.otherToneStyle(of: "thủy") == "thuỷ")
        #expect(VietnameseText.otherToneStyle(of: "ủy") == "uỷ")
        for unchanged in ["quả", "hoan", "hoa", "a", "toán", "nghĩa"] {
            #expect(VietnameseText.otherToneStyle(of: unchanged) == nil, "\(unchanged)")
        }
    }

    @Test func legalTextCleaningNormalisesLinesAndLetters() {
        let raw = "  Ðiều 1.\u{00A0}Phạm vi  \r\n\r\n\r\nthu\u{0309}y\u{2028}x\t y \n\n"
        #expect(LegalTexts.clean(raw) == "Điều 1. Phạm vi\n\nthủy\nx  y\n")
    }

    // MARK: SHA-256 and generated formats (ENG-R810)

    @Test func portableSHA256MatchesCryptoKit() {
        let inputs: [[UInt8]] = [
            [], Array("abc".utf8), Array(repeating: 0x61, count: 55), Array(repeating: 0x62, count: 56),
            Array(repeating: 0x63, count: 64), (0..<1_000).map { UInt8($0 % 251) },
        ]
        for bytes in inputs {
            let expected = CryptoKit.SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            #expect(lexicon_builder.SHA256.hex(of: bytes) == expected, "\(bytes.count) bytes")
        }
    }

    @Test func candidatesTSVSortsByCountThenBytes() {
        #expect(Builder.candidatesTSV(["b": 2, "a": 2, "c": 5]) == "token\tcount\nc\t5\na\t2\nb\t2\n")
    }

    @Test func manifestJSONHasAFixedKeyOrderAndDecodes() throws {
        let files: [(name: String, data: Data)] = [("a.txt", Data("x\n".utf8)), ("NOTICES.txt", Data("n\n".utf8))]
        let json = Builder.manifestJSON(
            files, entries: ["a.txt": 1], stats: [("words", 1), ("more", 2)], inputsDigest: "d")
        #expect(
            json.hasPrefix("{\n  \"format\": 3,\n  \"generator\": \"lexicon-builder\",\n  \"inputsSHA256\": \"d\","))
        #expect(json.contains("{\"name\": \"a.txt\", \"bytes\": 2, \"entries\": 1, \"sha256\": "))
        #expect(json.contains("{\"name\": \"NOTICES.txt\", \"bytes\": 2, \"sha256\": "))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["stats"] as? [String: Int]) == ["words": 1, "more": 2])
    }

    @Test func noticesIncludeLicenceFilesWithoutTrailingSpaces() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let licenses = root.appendingPathComponent("data/licenses")
        try write("Head\n@include extra.txt\nTail\n\n", to: licenses.appendingPathComponent("bundled-notices.txt"))
        try write("Line one   \nLine two\n", to: licenses.appendingPathComponent("extra.txt"))
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        #expect(try Builder.notices(layout) == "Head\nLine one\nLine two\n\nTail\n")
    }

    // MARK: Input manifest and builds

    @Test func manifestVerificationNamesChangedUnpinnedAndMissingFiles() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let data = root.appendingPathComponent("data")
        let layout = Layout(dataRoot: data, resources: root.appendingPathComponent("out"))
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        try InputManifest.verify(layout)
        try write("www\n", to: data.appendingPathComponent("inputs/tech-always.txt"))
        try write("new\n", to: data.appendingPathComponent("inputs/new.txt"))
        try FileManager.default.removeItem(at: data.appendingPathComponent("licenses/extra.txt"))
        do {
            try InputManifest.verify(layout)
            Issue.record("verification passed on changed inputs")
        } catch let error as BuilderError {
            #expect(error.description.contains("changed: inputs/tech-always.txt"))
            #expect(error.description.contains("not pinned: inputs/new.txt"))
            #expect(error.description.contains("missing: licenses/extra.txt"))
        }
        try write("not a manifest line\n", to: layout.manifestFile)
        #expect(throws: BuilderError.self) { try InputManifest.load(layout) }
    }

    @Test func buildIsAPureFunctionOfThePinnedInputs() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(
            dataRoot: root.appendingPathComponent("data"), resources: root.appendingPathComponent("out"))
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        let first = try Builder.build(layout)
        let second = try Builder.build(layout)
        #expect(first.resources.map(\.data) == second.resources.map(\.data))
        #expect(first.resources.map(\.name) == ResourceName.all)
        let attested = try #require(first.resources.first { $0.name == ResourceName.attested })
        // Legal-text tokens that are valid syllables, the additions and the other tone style of thủy.
        let syllables = String(decoding: attested.data, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(Set(syllables).isSuperset(of: ["điều", "luật", "thủy", "thuỷ", "á"]))
        #expect(!syllables.contains("đhqg"))
        try Builder.write(first, resources: layout.resources, derived: layout.derived)
        #expect(
            FileManager.default.fileExists(
                atPath: layout.derived.appendingPathComponent("attested-candidates.tsv").path))
    }

    @Test func buildRejectsGeneratedRowsWhoseReasonNoLongerHolds() throws {
        // Medium review finding: a generated `en` row records a consequence of rule L8 (display not attested)
        // or of the tech-always list. When the input it depends on changes, the row would silently keep
        // restoring the word, so the build (and therefore `check`) fails and names the row.
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(
            dataRoot: root.appendingPathComponent("data"), resources: root.appendingPathComponent("out"))
        let table = layout.inputs.appendingPathComponent("ambiguity.tsv")
        func build(rows: [String]) throws {
            try write(([AmbiguityRow.header] + rows).joined(separator: "\n") + "\n", to: table)
            try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
            _ = try Builder.build(layout)
        }
        let valid = [
            "is\ten\tproposed\tí\ten\tcontent\tgenerated [generated:unattested]",
            "www\ten\tproposed\tww\ten\tcontent\tgenerated [generated:tech-always]",
            "test\ten\tproposed\ttét\ten\tcontent\thand row, [generated: is not a token",
        ]
        try build(rows: valid)
        // á is attested (an addition of the fixture), so L8 no longer restores `as`.
        let attested = "as\ten\tproposed\tá\ten\tcontent\tgenerated [generated:unattested]"
        #expect(throws: BuilderError.self) { try build(rows: valid + [attested]) }
        // `tar` is a code-only word, not English (8.1), so L8 never restores it.
        let notEnglish = "tar\ten\tproposed\ttả\ten\tcontent\tgenerated [generated:unattested]"
        #expect(throws: BuilderError.self) { try build(rows: valid + [notEnglish]) }
        let notTechAlways = "usb\ten\tproposed\tú\ten\tcontent\tgenerated [generated:tech-always]"
        #expect(throws: BuilderError.self) { try build(rows: valid + [notTechAlways]) }
        do {
            try build(rows: valid + [attested])
        } catch let error as BuilderError {
            #expect("\(error)".contains("as"))
            #expect("\(error)".contains("attested"))
        }
    }

    @Test func proseCorpusTakesParagraphsRoundRobinAndChecksTheSize() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        try FileIO.write(try InputManifest.scan(layout).text, to: layout.manifestFile)
        let text = try ProseCorpus.generate(layout, minimumTokens: 3)
        #expect(text.hasSuffix("Điều Luật này quy định về thủy lợi\n"))
        #expect(text.contains("# Tokens: 8\n"))
        #expect(throws: BuilderError.self) { try ProseCorpus.generate(layout, minimumTokens: 1_000) }
    }
}

/// A SCOWL archive in the pinned layout (`scowl-2020.12.07/final/<member>`, `Copyright`, `README`), written into a
/// data root's `cache/` with its `SOURCES.tsv` row, so that `import scowl` runs offline on fixture data. Each member
/// holds its own name.
enum ScowlArchiveFixture {
    static func install(in layout: Layout, omitting omitted: String?) throws {
        let work = try TempDirectory.make("scowl-archive")
        defer { TempDirectory.remove(work) }
        let release = work.appendingPathComponent(Scowl.release)
        for file in Scowl.componentFiles + Scowl.guardListFiles where file != omitted {
            try write("\(file)\n", to: release.appendingPathComponent("final/\(file)"))
        }
        try write("SCOWL fixture copyright\n", to: release.appendingPathComponent("Copyright"))
        try write("SCOWL fixture readme\n", to: release.appendingPathComponent("README"))
        let archiveName = "\(Scowl.release).tar.gz"
        let archive = layout.cache.appendingPathComponent(archiveName)
        try FileManager.default.createDirectory(at: layout.cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: archive)
        _ = try FileIO.run("/usr/bin/tar", ["-czf", archive.path, "-C", work.path, Scowl.release])
        let data = try Data(contentsOf: archive)
        let header = DownloadSource.columns.joined(separator: "\t")
        let row = [
            Scowl.release, archiveName, "https://example.invalid/scowl.tar.gz", sha256Hex(data), "\(data.count)",
            "2026-11-19", "SCOWL fixture", "1", "2020-12-07", "fixture", "https://example.invalid",
        ].joined(separator: "\t")
        try write("\(header)\n\(row)\n", to: layout.inputs.appendingPathComponent("english/SOURCES.tsv"))
    }
}
