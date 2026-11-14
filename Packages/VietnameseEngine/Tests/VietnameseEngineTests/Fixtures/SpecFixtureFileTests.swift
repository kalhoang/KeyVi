// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Integrity of the corpus files extracted from spec 13.8 to 13.10 by
/// Scripts/extract-spec-examples.py (263 + 72 + 9 rows), and of the 13.9 fixture resources.
@Suite("Spec fixture files (13.8 to 13.10)")
struct SpecFixtureFileTests {
    @Test func workedExamples() throws {
        let rows = try SpecExamples.workedExamples(tsv: CorpusFiles.text(SpecExamples.workedExamplesFile))
        #expect(rows.count == 263)
        // REG-31: W243a to W243j follow W243; the suffix keeps the numbers of the rows after them.
        let numbered = (1...253).map { "W" + String(repeating: "0", count: 3 - String($0).count) + String($0) }
        let inserted = "abcdefghij".map { "W243" + String($0) }
        #expect(rows.map(\.id) == numbered.prefix(243) + inserted + numbered.suffix(10))
        #expect(Set(rows.map(\.options)) == ["-", "bracket keys on", "standalone w off"])
        #expect(rows.filter { $0.method == .vni }.map(\.id).count == 44)
        let first = try #require(rows.first)
        #expect(first.keys == "as" && first.expected == "á" && first.method == .telex && first.style == .traditional)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["W063"]?.style == .modern)
        #expect(byID["W090"]?.keys == "sooocs" && byID["W090"]?.expected == "soóc")
        #expect(
            byID["W236"]?.events == [
                .key(KeyInput("v")), .key(KeyInput("i")), .key(KeyInput("e")), .key(KeyInput("e")), .key(KeyInput("j")),
                .key(KeyInput("t")), .backspace,
            ])
        #expect(byID["W243f"]?.method == .vni && byID["W243f"]?.expected == "thư")
        #expect(byID["W243h"]?.keys == "nguowif ⌫⌫⌫" && byID["W243h"]?.expected == "ngư")
        #expect(byID["W244"]?.inputMethod == .telex(TelexOptions(bracketKeys: true)))
        #expect(byID["W246"]?.inputMethod == .telex(TelexOptions(standaloneW: false)))
        #expect(byID["W252"]?.configuration.inputMethod == .vni)
        #expect(byID["W253"]?.keys == "heoj" && byID["W253"]?.expected == "hẹo")
        // Backspace markers appear only in the Backspace group.
        #expect(rows.filter { $0.keys.contains("⌫") }.allSatisfy { $0.group == "Backspace inside a token" })
        #expect(rows.allSatisfy { !$0.keys.isEmpty && !$0.expected.isEmpty })
    }

    @Test func commitDecisions() throws {
        let rows = try SpecExamples.commitDecisions(tsv: CorpusFiles.text(SpecExamples.commitDecisionsFile))
        #expect(rows.count == 72)
        #expect(
            rows.map(\.id) == (1...72).map { "B" + String(repeating: "0", count: 3 - String($0).count) + String($0) })
        #expect(rows.prefix(52).allSatisfy { $0.boundary == " " })
        #expect(rows[52..<64].map(\.boundary) == [" ", ",", " ", ",", ",", ".", ";", "?", "!", ")", ":", "\n"])
        // 13.9.2 (ENG-R823, REG-32): a whole run of tokens per row, from an empty field.
        #expect(rows.suffix(8).map(\.boundary) == [".", ".", " ", " ", " ", " ", " ", " "])
        #expect(rows.suffix(8).allSatisfy { $0.previous == .none && $0.keys.contains(" ") })
        for row in rows {
            #expect(row.expectedText == row.committed + String(row.boundary), "\(row.id)")
            #expect(row.expectedDecision != nil, "\(row.id)")
            #expect(row.events.last == .key(KeyInput(row.boundary)))
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["B014"]?.expectedDecision == .kept(.escape) && byID["B014"]?.committed == "as")
        #expect(byID["B024"]?.expectedDecision == .restored(.ambiguityTable))
        #expect(byID["B034"]?.expectedDecision == .kept(.defaultVietnamese))
        #expect(byID["B035"]?.expectedDecision == .restored(.codeContext) && byID["B035"]?.context == .code)
        #expect(byID["B044"]?.expectedDecision == .kept(.unchanged))
        #expect(byID["B047"]?.method == .vni && byID["B047"]?.expectedDecision == .restored(.invalid))
        #expect(byID["B028"]?.previous == .english && byID["B028"]?.previous.seedKeys == "and")
        #expect(byID["B029"]?.previous == .vietnamese && byID["B029"]?.previous.seedKeys == "vieejt")
        #expect(byID["B053"]?.expectedText == "dzậy ")
        #expect(byID["B056"]?.ruleCode == "L7" && byID["B056"]?.outcome == .kept)
        #expect(byID["B064"]?.expectedText == "text\n" && byID["B064"]?.outcome == .restored)
        #expect(byID["B065"]?.committed == "Khúc cài các app cần thiết trên win cũng tricky á")
        #expect(byID["B065"]?.expectedDecision == .kept(.ambiguityTable))
        #expect(byID["B072"]?.expectedDecision == .restored(.englishRun))
    }

    @Test func restoreToggles() throws {
        let rows = try SpecExamples.restoreToggles(tsv: CorpusFiles.text(SpecExamples.restoreToggleFile))
        // 13.10 has E01 to E08 plus E02b.
        #expect(rows.map(\.id) == ["E01", "E02", "E02b", "E03", "E04", "E05", "E06", "E07", "E08"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["E03"]?.method == .vni && byID["E07"]?.configuration.inputMethod == .vni)
        #expect(
            byID["E04"]?.events == [
                .key(KeyInput("t")), .key(KeyInput("e")), .key(KeyInput("s")), .key(KeyInput("t")), .key(KeyInput(" ")),
                .backspace, .restoreToggle,
            ])
        #expect(byID["E02"]?.lastAction == .passThrough && byID["E01"]?.lastAction == .edit)
        #expect(byID["E02b"]?.expectedActive == "việ")
        #expect(byID["E06"]?.expectedActive == "" && byID["E06"]?.lastAction == .passThrough)
        #expect(byID["E08"]?.events.last == .restoreToggle)
    }

    @Test func fixtureListsMatchTheSpec() throws {
        let rows = try SpecExamples.commitFixtures(tsv: CorpusFiles.text(SpecExamples.commitFixturesFile))
        func values(_ kind: String) -> [String] { rows.filter { $0.kind == kind }.map(\.value) }
        #expect(values("english") == SpecFixtures.englishLexicon)
        #expect(values("techAlways") == SpecFixtures.techAlways)
        #expect(values("techCodeOnly") == SpecFixtures.techCodeOnly)
        #expect(values("unattested") == SpecFixtures.unattestedSyllables)
        let ambiguity = rows.filter { $0.kind == "ambiguity" }
        #expect(ambiguity.map(\.value) == SpecFixtures.ambiguityProposals.map(\.raw))
        #expect(ambiguity.map(\.display) == SpecFixtures.ambiguityProposals.map(\.display))
        #expect(
            ambiguity.map(\.decision) == SpecFixtures.ambiguityProposals.map { $0.language == .english ? "en" : "vi" })
    }

    @Test func commitResources() {
        let all = SpecFixtures.allStandardSyllables
        let attested = SpecFixtures.attestedSyllables
        #expect(SpecFixtures.unattestedSyllables.allSatisfy(all.contains))
        #expect(attested.count == all.count - SpecFixtures.unattestedSyllables.count)
        #expect(attested.contains("hòa") && attested.contains("hoà") && attested.contains("thuở"))
        #expect(!attested.contains("dóe") && !attested.contains("thưở"))
        // ENG-R820: every proposed ambiguity display is a Tier A syllable.
        for proposal in SpecFixtures.ambiguityProposals {
            #expect(Orthography.validity(of: proposal.display) == .standard, "\(proposal.display)")
        }
        let resources = SpecFixtures.commitResources(userKeepRaw: ["abc"])
        #expect(resources.english.contains("tomorrow") && !resources.english.contains("vieejt"))
        #expect(resources.techAlways.contains("www") && resources.techCodeOnly.contains("tar"))
        #expect(resources.attestedSyllables.contains("việt") && !resources.attestedSyllables.contains("ửa"))
        #expect(resources.ambiguity["test"] == .english && resources.ambiguity["as"] == .vietnamese)
        #expect(resources.userKeepRaw.contains("abc") && !resources.userKeepVietnamese.contains("abc"))
    }

    @Test func malformedFilesAreRejected() {
        #expect(throws: FixtureError.self) { try TSVTable(name: "empty", text: "# only a comment\n") }
        #expect(throws: FixtureError.self) { try TSVTable(name: "wide", text: "a\tb\n1\t2\t3\n") }
        #expect(throws: FixtureError.self) { try TSVTable(name: "escape", text: "a\nx\\q\n") }
        #expect(throws: FixtureError.self) {
            try SpecExamples.workedExamples(tsv: "id\tmethod\tstyle\nW1\tVNX\ttrad\n")
        }
        #expect(throws: FixtureError.self) { try SpecExamples.workedExamples(tsv: "id\tmethod\tstyle\nW1\tVNI\tnew\n") }
        #expect(throws: FixtureError.self) {
            try SpecExamples.commitDecisions(
                tsv: "id\tboundary\tmethod\tprevious\toutcome\tcontext\nB1\t\tVNI\tnone\tkept\tgeneral\n")
        }
        #expect(throws: FixtureError.self) {
            try SpecExamples.commitDecisions(
                tsv: "id\tboundary\tmethod\tprevious\toutcome\tcontext\nB1\t,\tVNI\tvi\tkept\tremote\n")
        }
        #expect(throws: FixtureError.self) {
            try SpecExamples.restoreToggles(tsv: "id\tmethod\tevents\tlast_action\nE1\tVNI\tjump\tedit\n")
        }
        #expect(throws: FixtureError.self) {
            try SpecExamples.restoreToggles(tsv: "id\tmethod\tevents\tlast_action\nE1\tVNI\ttoggle\tmaybe\n")
        }
    }

    @Test func escapesAndShortRows() throws {
        let table = try TSVTable(name: "escapes", text: "a\tb\tc\r\n\\sx\\s\ty\\t\\n\\\\\n# comment\n\nshort\n")
        #expect(table.header == ["a", "b", "c"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0]["a"] == " x " && table.rows[0]["b"] == "y\t\n\\" && table.rows[0]["c"] == "")
        #expect(table.rows[1]["a"] == "short" && table.rows[1]["b"] == "" && table.rows[1].line == 5)
        #expect(FixtureError(file: "f", line: 3, reason: "r").description == "f:3: r")
    }
}
