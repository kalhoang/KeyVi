// SPDX-License-Identifier: GPL-3.0-or-later
//
// Parsers behind `MacroImporter` (PRD-R32, PRD-R70). Every file is user-chosen and treated as untrusted: size is
// capped by the caller, JSON and property-list nesting is bounded before Foundation's recursive parsers run,
// and text is accepted as UTF-8 (with or without BOM) or UTF-16 with BOM (spreadsheet "Unicode text" exports).
// Expansions are normalised to NFC with LF line breaks, the form the engine expects (ENG-R1101).

internal import AppModel
internal import Foundation

enum MacroFormatSniffer {
    static func detect(_ data: Data, fileExtension: String?) -> MacroImportFormat? {
        if data.starts(with: MacroPlistParser.binaryMagic) { return .textReplacementsPlist }
        if let text = MacroText.decode(data) {
            let body = text.drop { $0.isWhitespace }
            if body.hasPrefix("<?xml") || body.hasPrefix("<plist") || body.hasPrefix("<!DOCTYPE plist") {
                return .textReplacementsPlist
            }
            if body.hasPrefix("{") || body.hasPrefix("["), (try? JSONSupport.parseValue(data)) != nil {
                return .appExport
            }
            if let format = delimitedFormat(text, fileExtension: fileExtension) { return format }
        }
        return format(forExtension: fileExtension)
    }

    /// Decides on the first line that carries data: tabs mean TSV, commas mean CSV; with both, a `.csv`
    /// extension picks CSV, otherwise TSV (a TSV expansion may well contain commas).
    private static func delimitedFormat(_ text: String, fileExtension: String?) -> MacroImportFormat? {
        guard let line = MacroText.lines(text).first(where: { !MacroText.isBlank($0) && !$0.hasPrefix("#") }) else {
            return nil
        }
        switch (line.contains("\t"), line.contains(",")) {
        case (true, false): return .tabSeparated
        case (false, true): return .csv
        case (true, true): return fileExtension == "csv" ? .csv : .tabSeparated
        case (false, false): return nil
        }
    }

    private static func format(forExtension fileExtension: String?) -> MacroImportFormat? {
        switch fileExtension {
        case "json": .appExport
        case "tsv", "tab", "txt": .tabSeparated
        case "csv": .csv
        case "plist": .textReplacementsPlist
        default: nil
        }
    }
}

enum MacroText {
    static func decode(_ data: Data) -> String? {
        let decoded: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data, encoding: .utf16)
        } else {
            let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
            decoded = String(data: Data(body), encoding: .utf8)
        }
        guard let text = decoded else { return nil }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// CR LF and lone CR become LF. Needed before splitting: Swift treats CR LF as one `Character`.
    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func lines(_ text: String) -> [Substring] {
        normalizedNewlines(text).split(separator: "\n", omittingEmptySubsequences: false)
    }

    static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

    static func expansion(_ raw: some StringProtocol) -> String {
        normalizedNewlines(String(raw)).precomposedStringWithCanonicalMapping
    }

    static func shortcut(_ raw: some StringProtocol) -> String {
        String(raw).trimmingCharacters(in: .whitespaces)
    }

    static func unreadable() -> [MacroImportRow] {
        [MacroImportRow(line: 1, shortcut: "", expansion: "", issue: .malformedLine)]
    }
}

// MARK: TAB-separated and CSV

enum MacroTextParser {
    static func parseTabSeparated(_ data: Data) -> [MacroImportRow] {
        guard let text = MacroText.decode(data) else { return MacroText.unreadable() }
        var rows: [MacroImportRow] = []
        for (index, line) in MacroText.lines(text).enumerated() {
            if MacroText.isBlank(line) || line.hasPrefix("#") { continue }
            guard let tab = line.firstIndex(of: "\t") else {
                rows.append(
                    MacroImportRow(
                        line: index + 1, shortcut: MacroText.shortcut(line), expansion: "", issue: .malformedLine))
                continue
            }
            let expansion = unescape(line[line.index(after: tab)...])
            rows.append(
                MacroImportRow(
                    line: index + 1, shortcut: MacroText.shortcut(line[..<tab]),
                    expansion: MacroText.expansion(expansion)))
        }
        return rows
    }

    /// `\n`, `\t`, `\\` decode to newline, tab, backslash; any other backslash is kept literally.
    static func unescape(_ text: Substring) -> String {
        var result = ""
        var pendingBackslash = false
        for character in text {
            if pendingBackslash {
                pendingBackslash = false
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
            } else if character == "\\" {
                pendingBackslash = true
            } else {
                result.append(character)
            }
        }
        if pendingBackslash { result.append("\\") }
        return result
    }

    static let knownHeaders: [(String, String)] = [
        ("shortcut", "expansion"), ("trigger", "expansion"), ("phím tắt", "nội dung"),
    ]

    static func parseCSV(_ data: Data) -> [MacroImportRow] {
        guard let text = MacroText.decode(data) else { return MacroText.unreadable() }
        var records = CSVReader.records(MacroText.normalizedNewlines(text)).filter { !$0.isBlank }
        if let first = records.first, isHeader(first.fields) { records.removeFirst() }
        return records.map(row(from:))
    }

    private static func row(from record: CSVRecord) -> MacroImportRow {
        let shortcut = MacroText.shortcut(record.fields.first ?? "")
        let extras = record.fields.dropFirst(2)
        guard !record.unterminated, extras.allSatisfy({ MacroText.shortcut($0).isEmpty }) else {
            return MacroImportRow(line: record.line, shortcut: shortcut, expansion: "", issue: .malformedLine)
        }
        let expansion = record.fields.count > 1 ? record.fields[1] : ""
        return MacroImportRow(line: record.line, shortcut: shortcut, expansion: MacroText.expansion(expansion))
    }

    private static func isHeader(_ fields: [String]) -> Bool {
        guard fields.count >= 2 else { return false }
        let pair = (headerKey(fields[0]), headerKey(fields[1]))
        return knownHeaders.contains { headerKey($0.0) == pair.0 && headerKey($0.1) == pair.1 }
    }

    private static func headerKey(_ text: String) -> String {
        MacroText.shortcut(text).lowercased().precomposedStringWithCanonicalMapping
    }
}

struct CSVRecord: Sendable, Hashable {
    var line: Int
    var fields: [String]
    var unterminated: Bool
    var isBlank: Bool { fields.count == 1 && fields[0].allSatisfy(\.isWhitespace) }
}

/// RFC 4180 reader over LF-normalised text. Lenient where the RFC is silent: a quote inside an unquoted field is
/// literal; an unterminated quoted field marks the last record.
enum CSVReader {
    static func records(_ text: String) -> [CSVRecord] {
        var state = State()
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if state.inQuotes, scalar == "\"", next < scalars.endIndex, scalars[next] == "\"" {
                state.field.append("\"")
                index = scalars.index(after: next)
                continue
            }
            state.consume(scalar)
            index = next
        }
        state.finish()
        return state.records
    }

    private struct State {
        var records: [CSVRecord] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var line = 1
        var recordLine = 1

        mutating func consume(_ scalar: Unicode.Scalar) {
            if inQuotes {
                if scalar == "\"" { inQuotes = false } else { append(scalar) }
                return
            }
            switch scalar {
            case "\"" where field.isEmpty: inQuotes = true
            case ",": endField()
            case "\n":
                endField()
                records.append(CSVRecord(line: recordLine, fields: fields, unterminated: false))
                fields = []
                line += 1
                recordLine = line
            default: field.append(scalar)
            }
        }

        mutating func finish() {
            guard inQuotes || !field.isEmpty || !fields.isEmpty else { return }
            endField()
            records.append(CSVRecord(line: recordLine, fields: fields, unterminated: inQuotes))
        }

        private mutating func append(_ scalar: Unicode.Scalar) {
            if scalar == "\n" { line += 1 }
            field.append(scalar)
        }

        private mutating func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
        }
    }
}

// MARK: JSON (own export, bare macros.json)

enum MacroJSONParser {
    static func parse(_ data: Data) -> [MacroImportRow] {
        guard let value = try? JSONSupport.parseValue(data) else { return MacroText.unreadable() }
        switch value {
        case .array(let items):
            return rows(fromItems: items)
        case .object(let object):
            if case .array(let items)? = object["macros"] { return rows(fromItems: items) }
            // A settings export with the macros box unticked carries no macros (PLT-R1010).
            return object["kind"]?.stringValue == SettingsExportFormat.kind ? [] : MacroText.unreadable()
        default:
            return MacroText.unreadable()
        }
    }

    /// Entry number (1-based) as the row's line.
    static func rows(fromItems items: [JSONValue]) -> [MacroImportRow] {
        items.enumerated().map { index, item in row(from: item, line: index + 1) }
    }

    private static func row(from item: JSONValue, line: Int) -> MacroImportRow {
        guard let object = item.objectValue else {
            return MacroImportRow(line: line, shortcut: "", expansion: "", issue: .malformedLine)
        }
        let shortcut = (object["trigger"] ?? object["shortcut"])?.stringValue ?? ""
        let expansion = (object["expansion"] ?? object["phrase"])?.stringValue ?? ""
        return MacroImportRow(
            line: line, shortcut: MacroText.shortcut(shortcut), expansion: MacroText.expansion(expansion),
            id: object["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            adaptCase: flag(object["adaptCase"]) ?? true, enabled: flag(object["enabled"]) ?? true)
    }

    private static func flag(_ value: JSONValue?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }
}

// MARK: Text Replacements property list

enum MacroPlistParser {
    static let binaryMagic = Array("bplist00".utf8)
    /// The Text Replacements file is an array of flat dictionaries (depth 2).
    static let maxNestingDepth = 16

    static func parse(_ data: Data) -> [MacroImportRow] {
        guard PlistNesting.isWithinLimit(data, limit: maxNestingDepth),
            let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any]
        else { return MacroText.unreadable() }
        return root.enumerated().map { index, item in
            guard let entry = item as? [String: Any] else {
                return MacroImportRow(line: index + 1, shortcut: "", expansion: "", issue: .malformedLine)
            }
            let shortcut = entry["shortcut"] as? String ?? ""
            let phrase = entry["phrase"] as? String ?? ""
            return MacroImportRow(
                line: index + 1, shortcut: MacroText.shortcut(shortcut), expansion: MacroText.expansion(phrase))
        }
    }
}
