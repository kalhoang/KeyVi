// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The keystroke notation of the hand-curated corpus files (spec/04-quality-release.md QA-R4) and of
/// the engine tests: one key event per character, except
///
/// - `⌫` Backspace,
/// - `⎋` restore toggle (7.2; the host binds it to a hotkey),
/// - `⟲` reset (10.2, reason `.unknown`; tests that need another reason send it directly),
/// - `⌨` before a digit: the digit comes from the numeric keypad (ENG-R401).
///
/// In corpus files the TSV escapes apply first (`\s` space, `\n` Return, `\t` Tab, `\\` backslash).
public enum KeyNotation {
    public static let backspace: Character = "⌫"
    public static let toggle: Character = "⎋"
    public static let reset: Character = "⟲"
    public static let keypad: Character = "⌨"

    public static func events(_ keys: String) -> [EngineEvent] {
        var events: [EngineEvent] = []
        var keypadNext = false
        for character in keys {
            switch character {
            case backspace: events.append(.backspace)
            case toggle: events.append(.restoreToggle)
            case reset: events.append(.reset(.unknown))
            case keypad: keypadNext = true
            default:
                events.append(.key(KeyInput(character, fromKeypad: keypadNext)))
                keypadNext = false
            }
        }
        return events
    }
}

/// One case of a QA-R4 corpus file: method, options, keystrokes, expected output and expected restore
/// output. The expected output is the whole simulated text field after the keystrokes; the expected
/// restore output is the field after one more restore toggle (`-` when the row does not check it).
public struct QACorpusCase: Sendable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let id: String
    public let method: FixtureMethod
    /// `-` or comma-separated flags: `modern`, `code`, `no-auto-restore`, `no-standalone-w`, `brackets`,
    /// `empty-resources` (no word lists instead of the 13.9 fixtures), `no-macros`, `history=N`.
    public let options: Set<String>
    public let keys: String
    public let expected: String
    /// Nil for `-`.
    public let expectedRestore: String?
    public let note: String

    public var description: String { "\(file):\(line) \(id) \(keys.debugDescription)" }

    public var events: [EngineEvent] { KeyNotation.events(keys) }

    public var configuration: EngineConfiguration {
        let inputMethod: InputMethod =
            method == .vni
            ? .vni
            : .telex(
                TelexOptions(
                    standaloneW: !options.contains("no-standalone-w"), bracketKeys: options.contains("brackets")))
        var historyLimit = 16
        for option in options where option.hasPrefix("history=") {
            historyLimit = Int(option.dropFirst("history=".count)) ?? historyLimit
        }
        return EngineConfiguration(
            inputMethod: inputMethod, toneStyle: options.contains("modern") ? .modern : .traditional,
            autoRestore: !options.contains("no-auto-restore"), appContext: options.contains("code") ? .code : .general,
            historyLimit: historyLimit)
    }

    /// The 13.9 fixture resources (or empty ones), with `macros` unless the row says `no-macros`.
    public func resources(macros: MacroTable) -> Resources {
        let table = options.contains("no-macros") ? MacroTable.empty : macros
        guard !options.contains("empty-resources") else {
            return Resources(
                english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
                attestedSyllables: WordSet([]), ambiguity: [:], userKeepRaw: WordSet([]),
                userKeepVietnamese: WordSet([]), macros: table)
        }
        return SpecFixtures.commitResources(macros: table)
    }
}

/// Loaders for the hand-curated QA-R4 corpus files under `Tests/VietnameseEngineTests/Corpus/`.
public enum QACorpus {
    public static let macrosFile = "macros.tsv"
    public static let macroTableFile = "macro-table.tsv"
    public static let editingFile = "editing.tsv"

    /// A case file: columns `id`, `method`, `options`, `keys`, `expected`, `restore`, `note`.
    public static func cases(file: String, tsv text: String) throws -> [QACorpusCase] {
        let table = try TSVTable(name: file, text: text)
        let required = ["id", "method", "options", "keys", "expected", "restore", "note"]
        guard required.allSatisfy(table.header.contains) else {
            throw FixtureError(file: file, line: 1, reason: "header must be \(required.joined(separator: " "))")
        }
        return try table.rows.map { row in
            guard let method = FixtureMethod(rawValue: row["method"]) else {
                throw FixtureError(file: file, line: row.line, reason: "unknown method \(row["method"])")
            }
            let options = row["options"] == "-" ? [] : Set(row["options"].split(separator: ",").map(String.init))
            let known: Set<String> = [
                "modern", "code", "no-auto-restore", "no-standalone-w", "brackets", "empty-resources", "no-macros",
            ]
            for option in options where !known.contains(option) && !option.hasPrefix("history=") {
                throw FixtureError(file: file, line: row.line, reason: "unknown option \(option)")
            }
            guard !row["keys"].isEmpty, !row["id"].isEmpty else {
                throw FixtureError(file: file, line: row.line, reason: "empty id or keys")
            }
            return QACorpusCase(
                file: file, line: row.line, id: row["id"], method: method, options: options, keys: row["keys"],
                expected: row["expected"], expectedRestore: row["restore"] == "-" ? nil : row["restore"],
                note: row["note"])
        }
    }

    /// The macro fixture table: columns `trigger`, `expansion`, `adapt_case` (`yes` / `no`). Throws the
    /// engine's validation error if the table is invalid.
    public static func macroTable(tsv text: String) throws -> MacroTable {
        let table = try TSVTable(name: macroTableFile, text: text)
        let entries = try table.rows.map { row -> MacroTable.Entry in
            guard row["adapt_case"] == "yes" || row["adapt_case"] == "no" else {
                throw FixtureError(file: macroTableFile, line: row.line, reason: "adapt_case must be yes or no")
            }
            return MacroTable.Entry(
                trigger: row["trigger"], expansion: row["expansion"], adaptCase: row["adapt_case"] == "yes")
        }
        return try MacroTable(entries)
    }

    /// Runs one case through an engine driver (simulated field, ENG-T31 checks after every event) and
    /// returns the field text and, if the row checks it, the field after one more restore toggle.
    public static func run(_ corpusCase: QACorpusCase, macros: MacroTable) throws -> (text: String, restore: String?) {
        var driver = EngineDriver(configuration: corpusCase.configuration, resources: corpusCase.resources(macros: macros))
        try driver.send(corpusCase.events)
        let text = driver.field.string
        guard corpusCase.expectedRestore != nil else { return (text, nil) }
        try driver.send(.restoreToggle)
        return (text, driver.field.string)
    }
}
