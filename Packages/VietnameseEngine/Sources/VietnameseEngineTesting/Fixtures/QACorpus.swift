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
    /// Backspace.
    public static let backspace: Character = "⌫"
    /// The restore toggle (7.2).
    public static let toggle: Character = "⎋"
    /// A reset with reason `.unknown` (10.2).
    public static let reset: Character = "⟲"
    /// Marks the next digit as typed on the numeric keypad (ENG-R401).
    public static let keypad: Character = "⌨"

    /// The events that `keys` denotes in this notation.
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

    /// The notation of `events` with the TSV escapes applied (`\s`, `\n`, `\r`, `\t`, `\\`), so that a
    /// failing fuzz stream can be pasted into a corpus file. Reset reasons are not kept (`⟲`).
    public static func render(_ events: [EngineEvent]) -> String {
        var text = ""
        for event in events {
            switch event {
            case .backspace: text.append(backspace)
            case .restoreToggle: text.append(toggle)
            case .reset: text.append(reset)
            case .key(let input):
                if input.fromKeypad { text.append(keypad) }
                switch input.character {
                case " ": text += "\\s"
                case "\n": text += "\\n"
                case "\r": text += "\\r"
                case "\r\n": text += "\\r\\n"
                case "\t": text += "\\t"
                case "\\": text += "\\\\"
                default: text.append(input.character)
                }
            }
        }
        return text
    }
}

/// One case of a QA-R4 corpus file: method, options, keystrokes, expected output and expected restore
/// output. The expected output is the whole simulated text field after the keystrokes; the expected
/// restore output is the field after one more restore toggle (`-` when the row does not check it).
public struct QACorpusCase: Sendable, Hashable, CustomStringConvertible {
    /// The corpus file the case comes from.
    public let file: String
    /// 1-based line number of the case in its file.
    public let line: Int
    /// The case identifier (unique across all corpus files).
    public let id: String
    /// Telex or VNI.
    public let method: FixtureMethod
    /// `-` or comma-separated flags: `modern`, `code`, `no-auto-restore`, `no-standalone-w`, `brackets`,
    /// `empty-resources` (no word lists instead of the 13.9 fixtures), `no-macros`, `history=N`,
    /// `qa-english` (the QA-R4 English hand list added to the fixture lexicon), `keep-vi=a|b` and
    /// `keep-raw=a|b` (the user keep-Vietnamese and keep-as-typed lists of 8.7).
    public let options: Set<String>
    /// The keystrokes, in `KeyNotation` with the TSV escapes and repetitions expanded.
    public let keys: String
    /// The whole simulated text field after the keystrokes.
    public let expected: String
    /// Nil for `-`.
    public let expectedRestore: String?
    /// Why the case exists (requirement, report or reading).
    public let note: String

    /// File, line, id and keys, for test reports.
    public var description: String { "\(file):\(line) \(id) \(keys.debugDescription)" }

    /// The events of the keystrokes.
    public var events: [EngineEvent] { KeyNotation.events(keys) }

    /// The engine configuration that the method and options describe.
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

    /// The 13.9 fixture resources (or empty ones), with `macros` unless the row says `no-macros`, the
    /// user lists the row names, and the QA-R4 English hand list when the row says `qa-english`.
    public func resources(macros: MacroTable) -> Resources {
        let table = options.contains("no-macros") ? MacroTable.empty : macros
        let keepVietnamese = listOption("keep-vi=")
        let keepRaw = listOption("keep-raw=")
        guard !options.contains("empty-resources") else {
            return Resources(
                english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
                attestedSyllables: WordSet([]), ambiguity: [:], userKeepRaw: WordSet(keepRaw),
                userKeepVietnamese: WordSet(keepVietnamese), macros: table)
        }
        var resources = SpecFixtures.commitResources(
            userKeepRaw: keepRaw, userKeepVietnamese: keepVietnamese, macros: table)
        if options.contains("qa-english") {
            resources.english = WordSet(SpecFixtures.englishLexicon + QACorpus.englishHandList)
        }
        return resources
    }

    private func listOption(_ prefix: String) -> [String] {
        options.filter { $0.hasPrefix(prefix) }.flatMap {
            $0.dropFirst(prefix.count).split(separator: "|").map(String.init)
        }
    }
}

/// Loaders for the hand-curated QA-R4 corpus files under `Tests/VietnameseEngineTests/Corpus/`.
public enum QACorpus {
    /// The QA-R4 `macros` case file.
    public static let macrosFile = "macros.tsv"
    /// The macro fixture table read by the `macros` cases.
    public static let macroTableFile = "macro-table.tsv"
    /// The QA-R4 `editing` case file.
    public static let editingFile = "editing.tsv"

    /// Every QA-R4 case file (one case per line, `cases(file:tsv:)`), run by one loader.
    public static let caseFiles = [
        "rhymes-rare.tsv", "no-shortcuts.tsv", "macros.tsv", "proper-nouns.tsv", "english.tsv", "collisions.tsv",
        "editing.tsv", "crash-regressions.tsv", "restore-exact.tsv", "layouts.tsv",
    ]

    /// The other files of the corpus folder: spec examples extracted by `Scripts/extract-spec-examples.py`
    /// and the macro fixture table.
    public static let fixtureFiles = [
        "worked-examples.tsv", "commit-decisions.tsv", "restore-toggle.tsv", "commit-fixtures.tsv", macroTableFile,
    ]

    /// QA-R4 `english`: the hand list of English words and tech terms that must restore unchanged.
    public static let englishHandList = [
        "text", "user", "case", "wifi", "usb", "with", "this", "year", "your", "our", "their", "early", "traffic",
        "current", "issue", "google", "github", "iphone", "macos",
    ]

    /// Expands the repetition notation of the corpus files: `«X»×N` stands for `X` written `N` times (long
    /// tokens of `crash-regressions`). `«`, `»` and `×` are reserved like the other notation characters.
    public static func expandRepetitions(_ field: String, file: String, line: Int) throws -> String {
        guard field.contains("«") else { return field }
        var result = ""
        var rest = Substring(field)
        while let open = rest.firstIndex(of: "«") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "»"), rest[close...].dropFirst().first == "×" else {
                throw FixtureError(file: file, line: line, reason: "bad repetition in \(field)")
            }
            let digits = rest[rest.index(close, offsetBy: 2)...].prefix(while: \.isNumber)
            guard let count = Int(digits), count > 0 else {
                throw FixtureError(file: file, line: line, reason: "bad repetition count in \(field)")
            }
            result += String(repeating: String(rest[rest.index(after: open)..<close]), count: count)
            rest = rest[digits.endIndex...]
        }
        return result + rest
    }

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
                "qa-english",
            ]
            let prefixes = ["history=", "keep-vi=", "keep-raw="]
            for option in options where !known.contains(option) && !prefixes.contains(where: option.hasPrefix) {
                throw FixtureError(file: file, line: row.line, reason: "unknown option \(option)")
            }
            guard !row["keys"].isEmpty, !row["id"].isEmpty else {
                throw FixtureError(file: file, line: row.line, reason: "empty id or keys")
            }
            func expanded(_ column: String) throws -> String {
                try expandRepetitions(row[column], file: file, line: row.line)
            }
            return QACorpusCase(
                file: file, line: row.line, id: row["id"], method: method, options: options, keys: try expanded("keys"),
                expected: try expanded("expected"),
                expectedRestore: row["restore"] == "-" ? nil : try expanded("restore"), note: row["note"])
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

    /// Runs one case through an `InvariantChecker` (the fuzz invariants of 13.6 after every event, the whole
    /// field kept) and returns the field text and, if the row checks it, the field after one more restore
    /// toggle.
    public static func run(_ corpusCase: QACorpusCase, macros: MacroTable) throws -> (text: String, restore: String?) {
        let engine = Engine(configuration: corpusCase.configuration, resources: corpusCase.resources(macros: macros))
        var options = InvariantChecker.Options()
        options.trimsField = false
        var checker = InvariantChecker(engine: engine, options: options)
        try checker.send(corpusCase.events)
        try checker.finish()
        let text = checker.fieldText
        guard corpusCase.expectedRestore != nil else { return (text, nil) }
        try checker.send(.restoreToggle)
        try checker.finish()
        return (text, checker.fieldText)
    }
}
