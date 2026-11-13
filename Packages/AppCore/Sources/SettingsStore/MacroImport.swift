// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Macro import (PRD-R32, PRD-R69, PRD-R70). Tolerant: invalid rows are skipped with a reason, one bad row
// never aborts the import, duplicates never overwrite without the user's choice.
//
// Accepted formats:
// - appExport: this app's settings export (`macros` array) or a bare macros.json.
// - tabSeparated: UTF-8 text, one `shortcut<TAB>expansion` per line; `\n`, `\t` and `\\` escapes in the
//   expansion decode to newline, tab and backslash; blank lines and lines starting with `#` are ignored.
// - csv: RFC 4180, two columns (shortcut, expansion), quoted fields may contain newlines; a first row equal to
//   a known header (`shortcut,expansion`, `trigger,expansion`, `phím tắt,nội dung`) is skipped.
// - textReplacementsPlist: property list array of dictionaries with `shortcut` and `phrase` keys, the file
//   produced by dragging entries out of System Settings > Keyboard > Text Replacements (VERIFY on macOS 27).

internal import AppModel
public import Foundation

public enum MacroImportFormat: String, Sendable, Hashable, CaseIterable {
    case appExport, tabSeparated, csv, textReplacementsPlist
}

/// Why a row was rejected (shown in the preview, PRD-R43 "Dòng 12: thiếu phần nội dung gõ tắt").
public enum MacroRowIssue: Sendable, Hashable {
    case emptyShortcut
    case emptyExpansion
    case shortcutTooLong  // > 32
    case shortcutHasWhitespace
    case shortcutNotPrintableASCII  // includes Vietnamese letters (PRD-R29)
    case expansionTooLong  // > 4,000
    case shadowedBy(shorter: String)  // shortcut = other shortcut + trailing punctuation (PRD-R29)
    case malformedLine
}

public struct MacroImportRow: Sendable, Hashable {
    public var line: Int
    public var shortcut: String
    public var expansion: String
    public var issue: MacroRowIssue?
}

public enum MacroDuplicateResolution: String, Sendable, Hashable { case keepMine, useImported }

public struct MacroImportPreview: Sendable, Hashable {
    public var new: [StoredMacro]
    public var duplicates: [(existing: StoredMacro, imported: StoredMacro)]
    public var invalid: [MacroImportRow]

    public static func == (lhs: MacroImportPreview, rhs: MacroImportPreview) -> Bool {
        lhs.new == rhs.new && lhs.invalid == rhs.invalid
            && lhs.duplicates.map(\.existing) == rhs.duplicates.map(\.existing)
            && lhs.duplicates.map(\.imported) == rhs.duplicates.map(\.imported)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(new)
        hasher.combine(invalid)
        hasher.combine(duplicates.map(\.imported))
    }
}

public enum MacroImporter {
    /// Sniffs content first (plist header, JSON object, tabs vs commas), then the extension.
    public static func detectFormat(_ data: Data, fileExtension: String?) -> MacroImportFormat? { unimplemented() }
    public static func parse(_ data: Data, format: MacroImportFormat) -> [MacroImportRow] { unimplemented() }
    /// Duplicates are by case-insensitive shortcut (matching is case-insensitive, ENG-R1101).
    public static func preview(_ rows: [MacroImportRow], existing: [StoredMacro]) -> MacroImportPreview {
        unimplemented()
    }

    public static func merge(_ preview: MacroImportPreview, into existing: [StoredMacro],
                             resolution: MacroDuplicateResolution) -> [StoredMacro] { unimplemented() }
}

/// Editor-side validation (PRD-R29). The engine's `MacroTable.init` stays authoritative when the table is
/// built; a test asserts both agree on every fixture.
public enum MacroValidator {
    public static let maxShortcutLength = 32
    public static let maxExpansionLength = 4_000
    public static func issue(shortcut: String, expansion: String, others: [StoredMacro]) -> MacroRowIssue? {
        unimplemented()
    }
}
