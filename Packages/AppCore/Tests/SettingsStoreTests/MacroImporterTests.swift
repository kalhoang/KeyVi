// SPDX-License-Identifier: LicenseRef-App-Pending

import Foundation
import Testing

@testable import SettingsStore

@Suite struct MacroImporterDetectionTests {
    @Test func sniffsContentBeforeExtension() throws {
        #expect(MacroImporter.detectFormat(Data(MacroFixtures.tabSeparated.utf8), fileExtension: "csv") == .tabSeparated)
        #expect(MacroImporter.detectFormat(Data(MacroFixtures.csv.utf8), fileExtension: "txt") == .csv)
        #expect(MacroImporter.detectFormat(Data(MacroFixtures.textReplacementsXML.utf8), fileExtension: nil) == .textReplacementsPlist)
        #expect(MacroImporter.detectFormat(try MacroFixtures.binaryPlist([]), fileExtension: nil) == .textReplacementsPlist)
        #expect(MacroImporter.detectFormat(Data(MacroFixtures.appExport.utf8), fileExtension: "txt") == .appExport)
        #expect(MacroImporter.detectFormat(Data(MacroFixtures.bareMacrosJSON.utf8), fileExtension: nil) == .appExport)
    }

    @Test func tabsAndCommasTieBreakOnExtension() {
        let both = Data("vn\tViệt Nam, quê hương\n".utf8)
        #expect(MacroImporter.detectFormat(both, fileExtension: "csv") == .csv)
        #expect(MacroImporter.detectFormat(both, fileExtension: "txt") == .tabSeparated)
    }

    @Test func fallsBackToExtension() {
        let plain = Data("onlyoneword\n".utf8)
        #expect(MacroImporter.detectFormat(plain, fileExtension: "TSV") == .tabSeparated)
        #expect(MacroImporter.detectFormat(plain, fileExtension: "csv") == .csv)
        #expect(MacroImporter.detectFormat(plain, fileExtension: "json") == .appExport)
        #expect(MacroImporter.detectFormat(plain, fileExtension: "plist") == .textReplacementsPlist)
        #expect(MacroImporter.detectFormat(plain, fileExtension: "doc") == nil)
        #expect(MacroImporter.detectFormat(Data([0xFF, 0xFF, 0x00, 0xC3]), fileExtension: nil) == nil)
        #expect(MacroImporter.detectFormat(Data("[not json".utf8), fileExtension: nil) == nil)
    }
}

@Suite struct MacroImporterParsingTests {
    @Test func tabSeparatedFixtureLinesAndReasonsPRDR70() {
        let rows = MacroImporter.parse(Data(MacroFixtures.tabSeparated.utf8), format: .tabSeparated)
        #expect(rows.map(\.line) == [2, 4, 5, 6, 7, 8, 9])
        #expect(rows[0] == MacroImportRow(line: 2, shortcut: "vn", expansion: "Việt Nam"))
        #expect(rows[1].expansion == "địa chỉ:\n123 Lê Lợi\tQ1\\")
        #expect(rows[1].issue == nil)
        #expect(rows[2].issue == .malformedLine)
        #expect(rows[3].issue == .shortcutNotPrintableASCII)
        #expect(rows[4].issue == .emptyExpansion)
        #expect(rows[5].shortcut == "sp" && rows[5].issue == nil)
        #expect(rows[6].issue == .shortcutTooLong)
    }

    @Test func unescapeKeepsUnknownEscapes() {
        #expect(MacroTextParser.unescape("a\\qb\\") == "a\\qb\\")
        #expect(MacroTextParser.unescape("\\\\n") == "\\n")
    }

    @Test func tabSeparatedAcceptsCRLFAndUTF16WithBOM() throws {
        let crlf = MacroImporter.parse(Data("vn\tViệt Nam\r\nkg\tkhông\r\n".utf8), format: .tabSeparated)
        #expect(crlf.map(\.shortcut) == ["vn", "kg"])
        #expect(crlf.map(\.expansion) == ["Việt Nam", "không"])
        let utf16 = try #require("vn\tViệt Nam\n".data(using: .utf16))
        #expect(MacroImporter.parse(utf16, format: .tabSeparated).map(\.expansion) == ["Việt Nam"])
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("vn\tA\n".utf8)
        #expect(MacroImporter.parse(bom, format: .tabSeparated).map(\.shortcut) == ["vn"])
    }

    @Test func expansionsAreNormalisedToNFC() {
        let decomposed = "Vie\u{0302}\u{0323}t"
        let rows = MacroImporter.parse(Data("vn\t\(decomposed)\n".utf8), format: .tabSeparated)
        #expect(rows.first?.expansion.unicodeScalars.count == 4)
        #expect(rows.first?.expansion == "Việt")
    }

    @Test func csvFixtureQuotingHeaderAndLines() {
        let rows = MacroImporter.parse(Data(MacroFixtures.csv.utf8), format: .csv)
        #expect(rows.map(\.line) == [2, 3, 5, 6, 7, 8])
        #expect(rows[0].shortcut == "vn" && rows[0].expansion == "Việt Nam" && rows[0].issue == nil)
        #expect(rows[1].expansion == "12 Lê Lợi,\nQuận 1")
        #expect(rows[2].expansion == "say \"hi\"")
        #expect(rows[3].issue == .malformedLine)
        #expect(rows[4].issue == .emptyExpansion)
        #expect(rows[5].issue == .malformedLine)
    }

    @Test func csvHeadersAreRecognisedInVietnameseToo() {
        let rows = MacroImporter.parse(Data("Phím tắt , Nội dung\nvn,Việt Nam\n".utf8), format: .csv)
        #expect(rows.map(\.shortcut) == ["vn"])
        let trailing = MacroImporter.parse(Data("vn,Việt Nam,,\n".utf8), format: .csv)
        #expect(trailing.first?.issue == nil)
    }

    @Test func textReplacementsXMLFixture() {
        let rows = MacroImporter.parse(Data(MacroFixtures.textReplacementsXML.utf8), format: .textReplacementsPlist)
        #expect(rows.count == 4)
        #expect(rows[0] == MacroImportRow(line: 1, shortcut: "vn", expansion: "Việt Nam"))
        #expect(rows[1].shortcut == "omw" && rows[1].issue == nil)
        #expect(rows[2].issue == .emptyShortcut)
        #expect(rows[3].issue == .malformedLine)
    }

    @Test func textReplacementsBinaryPlist() throws {
        let data = try MacroFixtures.binaryPlist([["shortcut": "vn", "phrase": "Việt Nam"], ["shortcut": "ty", "phrase": "cảm ơn"]])
        let rows = MacroImporter.parse(data, format: .textReplacementsPlist)
        #expect(rows.map(\.shortcut) == ["vn", "ty"])
        #expect(rows.allSatisfy { $0.issue == nil })
    }

    @Test func appExportFixtureKeepsIDsAndFlags() {
        let rows = MacroImporter.parse(Data(MacroFixtures.appExport.utf8), format: .appExport)
        #expect(rows.count == 4)
        #expect(rows[0].id == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        #expect(rows[1].adaptCase == false && rows[1].enabled == false && rows[1].id == nil)
        #expect(rows[2].issue == .shortcutHasWhitespace)
        #expect(rows[3].issue == .malformedLine && rows[3].line == 4)
        let bare = MacroImporter.parse(Data(MacroFixtures.bareMacrosJSON.utf8), format: .appExport)
        #expect(bare.map(\.shortcut) == ["ty"])
        let array = MacroImporter.parse(Data(#"[{"shortcut":"a1","phrase":"b"}]"#.utf8), format: .appExport)
        #expect(array.map(\.expansion) == ["b"])
        let exportWithoutMacros = Data(#"{"kind":"settings-export","schemaVersion":1}"#.utf8)
        #expect(MacroImporter.parse(exportWithoutMacros, format: .appExport).isEmpty)
    }

    @Test func unreadableFilesYieldOneMalformedRow() {
        let unreadable = [MacroImportRow(line: 1, shortcut: "", expansion: "", issue: .malformedLine)]
        #expect(MacroImporter.parse(Data([0xC3, 0x28]), format: .tabSeparated) == unreadable)
        #expect(MacroImporter.parse(Data([0xC3, 0x28]), format: .csv) == unreadable)
        #expect(MacroImporter.parse(Data("{".utf8), format: .appExport) == unreadable)
        #expect(MacroImporter.parse(Data(#"{"other":1}"#.utf8), format: .appExport) == unreadable)
        #expect(MacroImporter.parse(Data("12".utf8), format: .appExport) == unreadable)
        #expect(MacroImporter.parse(Data("not a plist".utf8), format: .textReplacementsPlist) == unreadable)
        #expect(MacroImporter.parse(Data("( { shortcut = vn; } )".utf8), format: .textReplacementsPlist) == unreadable)
        let tooBig = Data(count: MacroImporter.maxFileBytes + 1)
        #expect(MacroImporter.parse(tooBig, format: .tabSeparated) == unreadable)
        #expect(MacroImporter.parse(Data(), format: .tabSeparated).isEmpty)
    }

    @Test func deeplyNestedPlistsAreRefusedBeforeParsing() throws {
        let xml = "<plist><array>" + String(repeating: "<array>", count: 40) + String(repeating: "</array>", count: 40)
            + "</array></plist>"
        #expect(MacroImporter.parse(Data(xml.utf8), format: .textReplacementsPlist).first?.issue == .malformedLine)
        var nested: Any = ["leaf"]
        for _ in 0..<40 { nested = [nested] }
        let binary = try PropertyListSerialization.data(fromPropertyList: nested, format: .binary, options: 0)
        #expect(!PlistNesting.isWithinLimit(binary, limit: MacroPlistParser.maxNestingDepth))
        #expect(MacroImporter.parse(binary, format: .textReplacementsPlist).first?.issue == .malformedLine)
        var shallow: Any = ["leaf"]
        for _ in 0..<5 { shallow = [shallow, ["k": "v"]] }
        let ok = try PropertyListSerialization.data(fromPropertyList: shallow, format: .binary, options: 0)
        #expect(PlistNesting.isWithinLimit(ok, limit: MacroPlistParser.maxNestingDepth))
    }

    @Test func malformedBinaryPlistsAreRefused() throws {
        var data = try MacroFixtures.binaryPlist([["shortcut": "vn", "phrase": "x"]])
        #expect(!PlistNesting.isWithinLimit(Data(data.prefix(20)), limit: 16))
        data[data.count - 9] = 0xFF  // offset table pointer past the end
        #expect(!PlistNesting.isWithinLimit(data, limit: 16))
        #expect(MacroImporter.parse(data, format: .textReplacementsPlist).first?.issue == .malformedLine)
    }

    @Test func fuzzedBytesNeverCrashAnyParser() {
        var generator = SeededGenerator(seed: 0x5EED)
        for length in [0, 1, 7, 64, 300, 4_096] {
            for _ in 0..<40 {
                var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                if length > 8, Bool.random(using: &generator) { bytes.replaceSubrange(0..<8, with: Array("bplist00".utf8)) }
                let data = Data(bytes)
                for format in MacroImportFormat.allCases { _ = MacroImporter.parse(data, format: format) }
                _ = MacroImporter.detectFormat(data, fileExtension: nil)
            }
        }
    }
}

@Suite struct MacroImportPreviewTests {
    private let mine = [
        StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "hn.", expansion: "Hà Nội."),
    ]

    private func rows(_ pairs: [(String, String)]) -> [MacroImportRow] {
        pairs.enumerated().map { MacroImportRow(line: $0.offset + 1, shortcut: $0.element.0, expansion: $0.element.1) }
    }

    @Test func countsNewDuplicateAndInvalidPRDR32() {
        let preview = MacroImporter.preview(
            rows([("VN", "VIỆT NAM"), ("kg", "không"), ("", "x"), ("kg", "again")]), existing: mine)
        #expect(preview.new.map(\.trigger) == ["kg"])
        #expect(preview.duplicates.count == 1)
        #expect(preview.duplicates.first?.existing == mine[0])
        #expect(preview.duplicates.first?.imported.id == mine[0].id)
        #expect(preview.invalid.map(\.line) == [3, 4])
        #expect(preview.invalid.map(\.issue) == [.emptyShortcut, .duplicate(of: "kg")])
    }

    @Test func shadowingRejectsVnAndVnDotWhateverTheOrderPRDR29() {
        let forward = MacroImporter.preview(rows([("vn", "A"), ("vn.", "B")]), existing: [])
        let backward = MacroImporter.preview(rows([("vn.", "B"), ("vn", "A")]), existing: [])
        for preview in [forward, backward] {
            #expect(preview.new.map(\.trigger) == ["vn"])
            #expect(preview.invalid.map(\.issue) == [.shadowedBy(shorter: "vn")])
        }
    }

    @Test func shadowingAgainstExistingNeverDisplacesMine() {
        let preview = MacroImporter.preview(rows([("vn!", "x"), ("hn", "y"), ("hn!", "z")]), existing: mine)
        #expect(preview.invalid.map(\.issue) == [.shadowedBy(shorter: "vn"), .shadows(longer: "hn.")])
        // "hn!" is checked against accepted rows only: "hn" was rejected, so nothing shadows it.
        #expect(preview.new.map(\.trigger) == ["hn!"])
    }

    @Test func keepsImportedIDUnlessTaken() throws {
        let id = UUID()
        var first = MacroImportRow(line: 1, shortcut: "a1", expansion: "x")
        first.id = id
        var second = MacroImportRow(line: 2, shortcut: "b1", expansion: "y")
        second.id = id
        let preview = MacroImporter.preview([first, second], existing: [])
        #expect(preview.new.first?.id == id)
        #expect(preview.new.last?.id != id)
        let taken = MacroImporter.preview([first], existing: [StoredMacro(id: id, trigger: "zz", expansion: "q")])
        #expect(try #require(taken.new.first).id != id)
    }

    @Test func mergeKeepMineOrUseImportedPRDR70() {
        let preview = MacroImporter.preview(rows([("VN", "VIỆT NAM"), ("kg", "không")]), existing: mine)
        let kept = MacroImporter.merge(preview, into: mine, resolution: .keepMine)
        #expect(kept.map(\.expansion) == ["Việt Nam", "Hà Nội.", "không"])
        let replaced = MacroImporter.merge(preview, into: mine, resolution: .useImported)
        #expect(replaced.map(\.expansion) == ["VIỆT NAM", "Hà Nội.", "không"])
        #expect(replaced[0].id == mine[0].id)
        #expect(replaced[0].trigger == "VN")
    }

    @Test func mergeSkipsShortcutsTakenSinceThePreview() {
        let preview = MacroImporter.preview(rows([("kg", "không")]), existing: [])
        let now = [StoredMacro(id: preview.new[0].id, trigger: "KG", expansion: "mine")]
        #expect(MacroImporter.merge(preview, into: now, resolution: .useImported) == now)
        let other = [StoredMacro(id: preview.new[0].id, trigger: "zz", expansion: "mine")]
        let merged = MacroImporter.merge(preview, into: other, resolution: .keepMine)
        #expect(merged.count == 2)
        #expect(merged[1].id != merged[0].id)
    }

    @Test func previewEqualityAndHashing() {
        let a = MacroImporter.preview(rows([("VN", "x"), ("", "y")]), existing: mine)
        var b = a
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        b.duplicates = []
        #expect(a != b)
    }
}

/// Deterministic generator for fuzz loops (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
