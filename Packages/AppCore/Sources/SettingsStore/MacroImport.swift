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
    /// The other shortcut equals this one plus trailing punctuation, so this one would make it unreachable
    /// (engine `shadowedByShorterTrigger`, seen from the shorter side).
    case shadows(longer: String)
    /// Same shortcut, compared case-insensitively, as another entry (engine `duplicateTrigger`).
    case duplicate(of: String)
    case malformedLine
}

public struct MacroImportRow: Sendable, Hashable {
    /// 1-based line of a text file, or 1-based entry number in a JSON array or property list.
    public var line: Int
    public var shortcut: String
    public var expansion: String
    public var issue: MacroRowIssue?
    /// From this app's own export only; kept when it does not clash (contracts.md 7.3 "id regenerated on
    /// conflict"), so export then import reproduces the same macros.
    public var id: UUID?
    public var adaptCase: Bool
    public var enabled: Bool

    public init(
        line: Int, shortcut: String, expansion: String, issue: MacroRowIssue? = nil, id: UUID? = nil,
        adaptCase: Bool = true, enabled: Bool = true
    ) {
        self.line = line
        self.shortcut = shortcut
        self.expansion = expansion
        self.issue = issue
        self.id = id
        self.adaptCase = adaptCase
        self.enabled = enabled
    }
}

public enum MacroDuplicateResolution: String, Sendable, Hashable { case keepMine, useImported }

public struct MacroImportPreview: Sendable, Hashable {
    public var new: [StoredMacro]
    public var duplicates: [(existing: StoredMacro, imported: StoredMacro)]
    public var invalid: [MacroImportRow]

    public init(
        new: [StoredMacro] = [], duplicates: [(existing: StoredMacro, imported: StoredMacro)] = [],
        invalid: [MacroImportRow] = []
    ) {
        self.new = new
        self.duplicates = duplicates
        self.invalid = invalid
    }

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
    /// Files larger than this are refused before parsing (same cap as settings import, PLT-R912).
    public static let maxFileBytes = 5 * 1024 * 1024

    /// Sniffs content first (plist header, JSON object, tabs vs commas), then the extension.
    public static func detectFormat(_ data: Data, fileExtension: String?) -> MacroImportFormat? {
        MacroFormatSniffer.detect(data, fileExtension: fileExtension?.lowercased())
    }

    /// Rows in file order. Structural problems and per-row rules (PRD-R29) are filled in `issue`; duplicates
    /// and shadowing need the other rows and the user's macros, so `preview` decides those. A file that cannot
    /// be read at all yields one `malformedLine` row at line 1; an empty file yields no rows.
    public static func parse(_ data: Data, format: MacroImportFormat) -> [MacroImportRow] {
        guard data.count <= maxFileBytes else {
            return [MacroImportRow(line: 1, shortcut: "", expansion: "", issue: .malformedLine)]
        }
        let rows: [MacroImportRow]
        switch format {
        case .appExport: rows = MacroJSONParser.parse(data)
        case .tabSeparated: rows = MacroTextParser.parseTabSeparated(data)
        case .csv: rows = MacroTextParser.parseCSV(data)
        case .textReplacementsPlist: rows = MacroPlistParser.parse(data)
        }
        return rows.map(validated)
    }

    /// Duplicates are by case-insensitive shortcut (matching is case-insensitive, ENG-R1101).
    ///
    /// A valid row whose shortcut matches one of `existing` is a duplicate (resolved later by the user's
    /// choice); a repeat inside the file is invalid. Shadowing (PRD-R29) is checked against the user's macros in
    /// both directions and among the imported rows so that the longer shortcut is the one rejected, whatever
    /// the row order. Imported rows never displace an existing macro.
    public static func preview(_ rows: [MacroImportRow], existing: [StoredMacro]) -> MacroImportPreview {
        var existingByKey: [String: StoredMacro] = [:]
        for macro in existing where existingByKey[MacroValidator.key(macro.trigger)] == nil {
            existingByKey[MacroValidator.key(macro.trigger)] = macro
        }
        var preview = MacroImportPreview()
        var seen = Set<String>()
        var candidates: [MacroImportRow] = []
        for row in rows.map(validated) {
            let key = MacroValidator.key(row.shortcut)
            if row.issue != nil {
                preview.invalid.append(row)
            } else if !seen.insert(key).inserted {
                preview.invalid.append(rejected(row, .duplicate(of: row.shortcut)))
            } else if let mine = existingByKey[key] {
                preview.duplicates.append((mine, storedMacro(from: row, id: mine.id)))
            } else {
                candidates.append(row)
            }
        }
        addNew(candidates, existing: existing, to: &preview)
        preview.invalid.sort { $0.line < $1.line }
        return preview
    }

    /// Rows that conflict with the user's macros are rejected first; among the rest only the longer shortcut
    /// of a shadowing pair is rejected.
    private static func addNew(
        _ candidates: [MacroImportRow], existing: [StoredMacro], to preview: inout MacroImportPreview
    ) {
        let existingTriggers = existing.map(\.trigger)
        var accepted: [MacroImportRow] = []
        for row in candidates {
            if let issue = MacroValidator.shadowing(row.shortcut, against: existingTriggers) {
                preview.invalid.append(rejected(row, issue))
            } else {
                accepted.append(row)
            }
        }
        let acceptedShortcuts = accepted.map(\.shortcut)
        var usedIDs = Set(existing.map(\.id))
        for row in accepted {
            if let issue = MacroValidator.shadowedBy(row.shortcut, among: acceptedShortcuts) {
                preview.invalid.append(rejected(row, issue))
                continue
            }
            let id = row.id.flatMap { usedIDs.contains($0) ? nil : $0 } ?? UUID()
            usedIDs.insert(id)
            preview.new.append(storedMacro(from: row, id: id))
        }
    }

    /// `useImported` replaces each duplicate in place (keeping its id); `keepMine` leaves it. New macros are
    /// appended; an id that is taken by then gets a fresh one, and a shortcut that is taken by then is skipped.
    public static func merge(
        _ preview: MacroImportPreview, into existing: [StoredMacro],
        resolution: MacroDuplicateResolution
    ) -> [StoredMacro] {
        var result = existing
        if resolution == .useImported {
            for (mine, imported) in preview.duplicates {
                guard let index = result.firstIndex(where: { $0.id == mine.id }) else { continue }
                result[index] = StoredMacro(
                    id: mine.id, trigger: imported.trigger, expansion: imported.expansion,
                    adaptCase: imported.adaptCase, enabled: imported.enabled)
            }
        }
        var ids = Set(result.map(\.id))
        var keys = Set(result.map { MacroValidator.key($0.trigger) })
        for macro in preview.new where keys.insert(MacroValidator.key(macro.trigger)).inserted {
            var macro = macro
            if !ids.insert(macro.id).inserted {
                macro.id = UUID()
                ids.insert(macro.id)
            }
            result.append(macro)
        }
        return result
    }

    private static func validated(_ row: MacroImportRow) -> MacroImportRow {
        guard row.issue == nil else { return row }
        var row = row
        row.issue = MacroValidator.issue(shortcut: row.shortcut, expansion: row.expansion, others: [])
        return row
    }

    private static func rejected(_ row: MacroImportRow, _ issue: MacroRowIssue) -> MacroImportRow {
        var row = row
        row.issue = issue
        return row
    }

    private static func storedMacro(from row: MacroImportRow, id: UUID) -> StoredMacro {
        StoredMacro(
            id: id, trigger: row.shortcut, expansion: row.expansion, adaptCase: row.adaptCase, enabled: row.enabled)
    }
}

/// Editor-side validation (PRD-R29). The engine's `MacroTable.init` stays authoritative when the table is
/// built; a test asserts both agree on every fixture.
///
/// Agreement with `MacroTable.ValidationError` (ENG-R1101, ENG-R1103): `emptyTrigger` = `emptyShortcut`;
/// `triggerTooLong` = `shortcutTooLong` (more than 32); `invalidTriggerCharacter` = `shortcutHasWhitespace` or
/// `shortcutNotPrintableASCII` (only U+0021...U+007E are allowed); `expansionTooLong` = `expansionTooLong` (more
/// than 4,000 characters, counted as `String.count`); `duplicateTrigger` = `duplicate(of:)`;
/// `shadowedByShorterTrigger` = `shadowedBy(shorter:)` / `shadows(longer:)`. The editor is stricter in one place:
/// an empty expansion is rejected (`emptyExpansion`, PRD-R43 example).
public enum MacroValidator {
    public static let maxShortcutLength = 32
    public static let maxExpansionLength = 4_000

    /// First problem of `shortcut -> expansion` among `others` (pass every macro except the one being edited;
    /// disabled macros count, because enabling one later must not produce a table the engine rejects).
    public static func issue(shortcut: String, expansion: String, others: [StoredMacro]) -> MacroRowIssue? {
        if let issue = shortcutIssue(shortcut) { return issue }
        if expansion.isEmpty { return .emptyExpansion }
        if expansion.count > maxExpansionLength { return .expansionTooLong }
        let key = key(shortcut)
        if let same = others.first(where: { Self.key($0.trigger) == key }) { return .duplicate(of: same.trigger) }
        return shadowing(shortcut, against: others.map(\.trigger))
    }

    static func shortcutIssue(_ shortcut: String) -> MacroRowIssue? {
        if shortcut.isEmpty { return .emptyShortcut }
        if shortcut.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { return .shortcutHasWhitespace }
        if !shortcut.unicodeScalars.allSatisfy(isPrintableASCII) { return .shortcutNotPrintableASCII }
        if shortcut.unicodeScalars.count > maxShortcutLength { return .shortcutTooLong }
        return nil
    }

    /// Shadowing in both directions against existing shortcuts (ENG-R1103).
    static func shadowing(_ shortcut: String, against triggers: [String]) -> MacroRowIssue? {
        let key = key(shortcut)
        if let shorter = triggers.first(where: { isShadowed(key, by: Self.key($0)) }) {
            return .shadowedBy(shorter: shorter)
        }
        if let longer = triggers.first(where: { isShadowed(Self.key($0), by: key) }) { return .shadows(longer: longer) }
        return nil
    }

    /// Only the longer side of a pair is rejected among imported rows.
    static func shadowedBy(_ shortcut: String, among shortcuts: [String]) -> MacroRowIssue? {
        let key = key(shortcut)
        return shortcuts.first { isShadowed(key, by: Self.key($0)) }.map { .shadowedBy(shorter: $0) }
    }

    /// `longer` is `shorter` followed by one or more ASCII punctuation characters: typing the punctuation after
    /// `shorter` already expands it, so `longer` can never fire (PRD-R29, ENG-R1103: `vn` vs `vn.`).
    static func isShadowed(_ longer: String, by shorter: String) -> Bool {
        guard !shorter.isEmpty, longer.count > shorter.count, longer.hasPrefix(shorter) else { return false }
        return longer.unicodeScalars.dropFirst(shorter.unicodeScalars.count).allSatisfy(isASCIIPunctuation)
    }

    /// Matching key: ASCII-lowercased shortcut (ENG-R1101 case-insensitive matching).
    static func key(_ shortcut: String) -> String { shortcut.lowercased() }

    static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool { (0x21...0x7E).contains(scalar.value) }

    static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        isPrintableASCII(scalar) && !(scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }
}
