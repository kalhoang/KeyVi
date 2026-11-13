// SPDX-License-Identifier: GPL-3.0-or-later
//
// Macros pane (PRD-R29, PRD-R31): the editor rejects invalid shortcuts with the PRD-R29 reasons, stores
// expansions in NFC (ENG-R1101), never saves a table the engine rejects (ENG-R1103), refuses a trailing digit like
// trailing punctuation, and the list supports search, sort, add, edit, duplicate, delete and enable or disable all.

import AppModel
import Foundation
import SettingsStore
import Testing
import VietnameseEngine

@testable import ShellCore

@Suite struct MacroEditorTests {
    let vn = StoredMacro(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, trigger: "vn", expansion: "Việt Nam")
    let dc = StoredMacro(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, trigger: "dc", expansion: "được")
    let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    func list() -> MacroListState { MacroListState(macros: [vn, dc]) }

    @Test func invalidShortcutsAreRejectedWithThePRDR29Reasons() throws {
        var state = list()
        let cases: [(String, String, MacroRowIssue)] = [
            ("", "x", .emptyShortcut),
            ("a b", "x", .shortcutHasWhitespace),
            ("đc", "được", .shortcutNotPrintableASCII),
            (String(repeating: "a", count: 33), "x", .shortcutTooLong),
            ("ok", "", .emptyExpansion),
            ("ok", String(repeating: "a", count: 4_001), .expansionTooLong),
            ("VN", "x", .duplicate(of: "vn")),  // case-insensitive (ENG-R1101)
            ("vn.", "x", .shadowedBy(shorter: "vn")),  // PRD-R29
            ("vn.x", "x", .shadowedBy(shorter: "vn")),
        ]
        for (shortcut, expansion, issue) in cases {
            let result = state.save(MacroDraft(shortcut: shortcut, expansion: expansion))
            #expect(result == .failure(.invalid(issue)), "\(shortcut)")
        }
        // The shorter side is refused too when the longer one exists.
        var withLonger = MacroListState(macros: [StoredMacro(trigger: "ad.", expansion: "address")])
        #expect(
            withLonger.save(MacroDraft(shortcut: "ad", expansion: "x"))
                == .failure(.invalid(.shadows(longer: "ad."))))
        #expect(state.macros == [vn, dc])  // nothing saved
    }

    @Test func reasonsAreExplainedWithTheirShortcut() throws {
        let l = try Localizers()
        #expect(
            MacroIssueText.text(.shortcutNotPrintableASCII, shortcut: "đc", localizer: l.vi).contains(
                "dc, không phải đc"))
        #expect(
            MacroIssueText.text(.shadowedBy(shorter: "vn"), shortcut: "vn.", localizer: l.vi)
                == "\"vn.\" là gõ tắt \"vn\" thêm dấu câu hoặc chữ số, nên \"vn\" luôn chạy trước và \"vn.\" không bao giờ dùng được."
        )
        #expect(
            MacroIssueText.text(.shadows(longer: "ad."), shortcut: "ad", localizer: l.en)
                == "The macro \"ad.\" is \"ad\" plus punctuation or a digit, so with \"ad\" the macro \"ad.\" could never be used."
        )
        let issues: [MacroRowIssue] = [
            .emptyShortcut, .emptyExpansion, .shortcutTooLong, .shortcutHasWhitespace, .expansionTooLong,
            .duplicate(of: "vn"), .malformedLine,
        ]
        for issue in issues {
            let text = MacroIssueText.text(issue, shortcut: "x", localizer: l.vi)
            #expect(!text.isEmpty && !text.hasPrefix("macros."), "\(issue)")
        }
        let row = MacroImportRow(line: 12, shortcut: "vn", expansion: "", issue: .emptyExpansion)
        #expect(MacroIssueText.lineText(row, localizer: l.vi) == "Dòng 12: thiếu phần nội dung gõ tắt.")
        #expect(MacroIssueText.lineText(MacroImportRow(line: 1, shortcut: "a", expansion: "b"), localizer: l.vi) == "")
        let problem = MacroTableProblem(trigger: "vn.", issue: .shadowedBy(shorter: "vn"))
        #expect(MacroIssueText.entryText(problem, localizer: l.vi).hasPrefix("Gõ tắt \"vn.\": "))
    }

    @Test func expansionsAreStoredInNFC_ENGR1101() throws {
        var state = list()
        let decomposed = "Vie\u{0302}\u{0323}t"  // NFD "Việt"
        let result = state.save(MacroDraft(shortcut: "vt", expansion: decomposed), newID: { fixedID })
        let saved = try result.get()
        #expect(saved.expansion == "Việt")
        #expect(saved.expansion.unicodeScalars.count == 4)
        #expect(state.macros.last == saved)
        #expect(saved.id == fixedID)
    }

    @Test func editingKeepsTheIDAndRevalidatesAgainstOthersOnly() throws {
        var state = list()
        var draft = try #require(state.draft(for: vn.id))
        #expect(draft.shortcut == "vn" && draft.id == vn.id)
        draft.expansion = "Việt Nam!"
        draft.adaptCase = false
        let saved = try state.save(draft).get()
        #expect(saved.id == vn.id && !saved.adaptCase)
        #expect(state.macros.map(\.expansion) == ["Việt Nam!", "được"])
        // Renaming onto another shortcut is a duplicate.
        draft.shortcut = "DC"
        #expect(state.save(draft) == .failure(.invalid(.duplicate(of: "dc"))))
        // A vanished macro cannot be saved.
        state.delete(vn.id)
        draft.shortcut = "vn2"
        #expect(state.save(draft) == .failure(.notFound))
        #expect(state.draft(for: vn.id) == nil)
    }

    @Test func duplicateOpensACopyThatMustGetANewShortcut() throws {
        var state = list()
        var copy = try #require(state.duplicateDraft(of: dc.id))
        #expect(copy.id == nil && copy.expansion == "được")
        #expect(state.save(copy) == .failure(.invalid(.duplicate(of: "dc"))))
        copy.shortcut = "dk"
        _ = try state.save(copy).get()
        #expect(state.macros.map(\.trigger) == ["vn", "dc", "dk"])
        #expect(state.duplicateDraft(of: UUID()) == nil)
    }

    /// ENG-R1103, PRD-R29 (decision of 13/11/2026): a shortcut that is another one plus a trailing digit is refused
    /// in both directions and for both typing methods, with the same explanation as trailing punctuation.
    @Test func aTrailingDigitIsRefusedLikePunctuation_ENGR1103() throws {
        let macros = [StoredMacro(trigger: "k", expansion: "không")]
        let longer = MacroDraftValidator.check(MacroDraft(shortcut: "k1", expansion: "x"), among: macros)
        #expect(longer.issue == .shadowedBy(shorter: "k"))
        let shorter = MacroDraftValidator.check(
            MacroDraft(shortcut: "K", expansion: "x"), among: [StoredMacro(trigger: "k2", expansion: "y")])
        #expect(shorter.issue == .shadows(longer: "k2"))
        #expect(MacroDraftValidator.check(MacroDraft(shortcut: "ka", expansion: "x"), among: macros).canSave)
        var state = MacroListState(macros: macros)
        #expect(state.save(MacroDraft(shortcut: "k1", expansion: "x")) == .failure(.invalid(.shadowedBy(shorter: "k"))))
        #expect(state.macros == macros)
        let l = try Localizers()
        #expect(
            MacroIssueText.text(.shadowedBy(shorter: "k"), shortcut: "k1", localizer: l.vi)
                == "\"k1\" là gõ tắt \"k\" thêm dấu câu hoặc chữ số, nên \"k\" luôn chạy trước và \"k1\" không bao giờ dùng được."
        )
        #expect(
            MacroIssueText.text(.shadows(longer: "k2"), shortcut: "K", localizer: l.en)
                == "The macro \"k2\" is \"K\" plus punctuation or a digit, so with \"K\" the macro \"k2\" could never be used."
        )
    }

    @Test func engineErrorsMapToRowReasons_ENGR1103() {
        let macros = [vn, StoredMacro(trigger: "VN", expansion: "x"), StoredMacro(trigger: "ad", expansion: "y")]
        #expect(
            MacroDraftValidator.engineProblem(in: macros)
                == MacroTableProblem(trigger: "VN", issue: .duplicate(of: "vn")))
        let cases: [(MacroTable.ValidationError, MacroRowIssue)] = [
            (.emptyTrigger(""), .emptyShortcut),
            (.triggerTooLong("x"), .shortcutTooLong),
            (.invalidTriggerCharacter("a b"), .shortcutHasWhitespace),
            (.invalidTriggerCharacter("đc"), .shortcutNotPrintableASCII),
            (.expansionTooLong("x"), .expansionTooLong),
            (.shadowedByShorterTrigger(trigger: "ad.", shorter: "ad"), .shadowedBy(shorter: "ad")),
            (.duplicateTrigger("Zz"), .duplicate(of: "Zz")),
        ]
        for (error, issue) in cases {
            #expect(MacroDraftValidator.problem(for: error, macros: macros).issue == issue, "\(error)")
        }
        #expect(MacroDraftValidator.engineProblem(in: [vn, dc]) == nil)
        let shadowed = [StoredMacro(trigger: "ad", expansion: "y"), StoredMacro(trigger: "ad.x", expansion: "z")]
        #expect(MacroDraftValidator.engineProblem(in: shadowed)?.issue == .shadowedBy(shorter: "ad"))
    }

    @Test func editorAndEngineAgreeOnEverySavedTable() {
        // Whatever the editor accepts, the engine accepts (W1-B cross-track rule). `vn1` and `k1` are refused: a
        // trailing digit counts like punctuation (ENG-R1103).
        var state = MacroListState(macros: [])
        let shortcuts = ["vn", "vn1", "@@", "@@x", "ad", "a.d", "k", "k1", "btw", "ty", "x.y.z"]
        for shortcut in shortcuts {
            _ = state.save(MacroDraft(shortcut: shortcut, expansion: "e"))
        }
        #expect(MacroDraftValidator.engineProblem(in: state.macros) == nil)
        #expect(state.macros.map(\.trigger) == shortcuts.filter { $0 != "vn1" && $0 != "k1" })
    }

    @Test func searchSortAndBulkToggles_PRDR31() {
        var state = MacroListState(macros: [
            StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "btw", expansion: "by the way"),
            StoredMacro(trigger: "dc", expansion: "được"),
        ])
        state.searchText = "viet"  // ignores case and marks
        #expect(state.visible.map(\.trigger) == ["vn"])
        state.searchText = "B"
        #expect(state.visible.map(\.trigger) == ["btw"])
        state.searchText = "  "
        #expect(state.visible.count == 3)
        state.sort = .shortcut
        #expect(state.visible.map(\.trigger) == ["btw", "dc", "vn"])
        state.sort = .expansion
        #expect(state.visible.map(\.trigger) == ["btw", "dc", "vn"])
        state.sort = .orderAdded
        #expect(state.visible.map(\.trigger) == ["vn", "btw", "dc"])
        #expect(MacroSortOrder.allCases.map(\.title) == [.sortOrderAdded, .sortShortcut, .sortExpansion])

        state.setAllEnabled(false)
        #expect(state.allDisabled && !state.allEnabled)
        state.setEnabled(true, for: state.macros[1].id)
        #expect(!state.allDisabled && !state.allEnabled)
        state.setEnabled(true, for: UUID())
        state.setAllEnabled(true)
        #expect(state.allEnabled)
        state.delete(state.macros[0].id)
        #expect(state.macros.map(\.trigger) == ["btw", "dc"])
        state.replace(with: [])
        #expect(state.isEmpty)
    }

    @Test func storedProblemsAreShownPerRow() {
        let state = MacroListState(macros: [
            StoredMacro(trigger: "vn", expansion: "Việt Nam"), StoredMacro(trigger: "vn.", expansion: "x"),
            StoredMacro(trigger: "ok", expansion: ""),
        ])
        let issues = state.rowIssues
        #expect(issues[state.macros[0].id] == .shadows(longer: "vn."))
        #expect(issues[state.macros[1].id] == .shadowedBy(shorter: "vn"))
        #expect(issues[state.macros[2].id] == .emptyExpansion)
    }
}
