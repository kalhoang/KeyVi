// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Nhập từ tệp..." (PRD-R32, PRD-R43, PRD-R70): preview counts equal SettingsStore's importer (W1-B), refused
// files are explained with their line, merges follow the duplicate choice, expansions are saved in NFC, and the
// macro export reads back through the importer.

import AppModel
import Foundation
import SettingsStore
import Testing

@testable import ShellCore

@Suite struct MacroImportFlowTests {
    let mine = [StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "ko", expansion: "không")]

    @Test func previewCountsMatchTheImporter() throws {
        let text = "vn\tViet Nam\ndc\tđược\nbad key\tx\ntphcm\tThành phố Hồ Chí Minh\nempty\t\n"
        let data = Data(text.utf8)
        let session = try MacroImportSession.open(data, fileExtension: "txt", existing: mine).get()
        let importer = MacroImporter.preview(MacroImporter.parse(data, format: .tabSeparated), existing: mine)
        // New rows get fresh ids, so compare what the user sees: counts, shortcuts and invalid rows.
        #expect(session.preview.new.map(\.trigger) == importer.new.map(\.trigger))
        #expect(session.preview.duplicates.map(\.imported.trigger) == importer.duplicates.map(\.imported.trigger))
        #expect(session.preview.invalid == importer.invalid)
        #expect(session.newCount == 2 && session.duplicateCount == 1 && session.invalidCount == 2)
        let l = try Localizers()
        #expect(
            session.invalidLines(l.vi) == [
                "Dòng 3: Phím tắt không được có khoảng trắng.", "Dòng 5: Thiếu phần nội dung gõ tắt.",
            ])
        #expect(l.vi.format(MacrosText.importNew, session.newCount) == "Mới: 2")
    }

    @Test func mergeFollowsTheDuplicateChoiceAndNormalizesToNFC() throws {
        let csv = "shortcut,expansion\nvn,Viet Nam\nvt,\"Vie\u{0302}\u{0323}t\"\n"
        var session = try MacroImportSession.open(Data(csv.utf8), fileExtension: "csv", existing: mine).get()
        let kept = try session.merged(into: mine).get()
        #expect(kept.first { $0.trigger == "vn" }?.expansion == "Việt Nam")  // keep mine (default)
        #expect(kept.first { $0.trigger == "vt" }?.expansion == "Việt")  // ENG-R1101 NFC
        session.resolution = .useImported
        let replaced = try session.merged(into: mine).get()
        #expect(replaced.first { $0.trigger == "vn" }?.expansion == "Viet Nam")
        #expect(replaced.count == 3)
    }

    @Test func textReplacementsPlistIsAccepted() throws {
        let plist: [[String: String]] = [["shortcut": "omw", "phrase": "On my way!"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let session = try MacroImportSession.open(data, fileExtension: "plist", existing: []).get()
        #expect(session.newCount == 1)
    }

    @Test func refusedFilesAreExplained_PRDR43() throws {
        let l = try Localizers()
        let big = Data(count: MacroImporter.maxFileBytes + 1)
        #expect(MacroImportSession.open(big, fileExtension: "txt", existing: []) == .failure(.tooLarge))
        #expect(MacroImportSession.open(Data(), fileExtension: "txt", existing: []) == .failure(.empty))
        let allInvalid = Data("a b\tx\n\n# comment\nlong\t\n".utf8)
        guard case .failure(let refusal) = MacroImportSession.open(allInvalid, fileExtension: "txt", existing: mine)
        else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.message(l.vi).hasPrefix("Tệp này không đúng định dạng."))
        let onlyInvalid = Data("vn x\tViệt Nam\nok\t\n".utf8)
        let result = MacroImportSession.open(onlyInvalid, fileExtension: "txt", existing: [])
        guard case .failure(.invalidFile(let row?)) = result else {
            Issue.record("expected the first bad line")
            return
        }
        #expect(row.line == 1)
        #expect(
            MacroImportRefusal.invalidFile(
                firstInvalid: MacroImportRow(line: 12, shortcut: "x", expansion: "", issue: .emptyExpansion)
            )
            .message(l.vi) == "Tệp này không đúng định dạng. Dòng 12: Thiếu phần nội dung gõ tắt.")
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01])
        let unreadable = MacroImportSession.open(garbage, fileExtension: "json", existing: [])
        #expect(unreadable == .failure(.invalidFile(firstInvalid: nil)))
        #expect(
            MacroImportRefusal.invalidFile(firstInvalid: nil).message(l.en)
                == "This file is not in the expected format.")
        #expect(MacroImportRefusal.tooLarge.message(l.vi) == "Tệp này lớn hơn 5 MB.")
        #expect(MacroImportRefusal.empty.message(l.vi) == "Tệp này không có gõ tắt nào.")
    }

    @Test func exportReadsBackThroughTheImporter() throws {
        let macros = [
            StoredMacro(trigger: "vn", expansion: "Việt Nam", adaptCase: false, enabled: false),
            StoredMacro(trigger: "dc", expansion: "được\nxuống dòng"),
        ]
        let data = try MacroExport.data(macros)
        #expect(MacroImporter.detectFormat(data, fileExtension: "json") == .appExport)
        let session = try MacroImportSession.open(data, fileExtension: "json", existing: []).get()
        #expect(session.preview.new == macros)  // ids, flags and multi-line text survive
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            MacroExport.fileName(slug: "app", date: Date(timeIntervalSince1970: 1_794_528_000), timeZone: utc)
                == "app-macros-20261113.json")
    }
}

@Suite struct MacroImportFormatTests {
    @Test func anUnrecognisedFileIsRefusedWithoutALine() {
        let binary = Data([0x00, 0x01, 0x02, 0x03])
        let result = MacroImportSession.open(binary, fileExtension: nil, existing: [])
        #expect(result == .failure(.invalidFile(firstInvalid: nil)))
    }
}
