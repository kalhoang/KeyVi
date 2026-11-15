// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// Method column of the spec tables.
public enum FixtureMethod: String, Sendable, Hashable {
    case telex = "Telex"
    case vni = "VNI"
}

/// Language of the previous token in a commit example (13.9 "Previous token", 8.3).
public enum PreviousToken: String, Sendable, Hashable {
    case none
    case vietnamese = "vi"
    case english = "en"

    /// Keys of a seed token that gives the run this language under ENG-R823 with the 13.9 fixtures:
    /// `việt` contains Vietnamese-only letters; `and` is an unchanged lexicon word that is not valid
    /// Vietnamese. Nil for `none`. Callers type the seed and a space before the example.
    public var seedKeys: String? {
        switch self {
        case .none: return nil
        case .vietnamese: return "vieejt"
        case .english: return "and"
        }
    }
}

/// A worked composition example of spec 13.8 (W001-W253 with the lettered rows W158a to W243o).
public struct WorkedExample: Sendable, Hashable {
    /// The row identifier of the spec (W001, W243a, B001, E01).
    public let id: String
    /// The group column of 13.8.
    public let group: String
    /// Telex or VNI.
    public let method: FixtureMethod
    /// Traditional or modern tone placement.
    public let style: ToneStyle
    /// The options column verbatim (`-`, `bracket keys on`, `standalone w off`).
    public let options: String
    /// Keys typed; `⌫` is Backspace.
    public let keys: String
    /// Display after the last key, before any boundary.
    public let expected: String
    /// The note column of the spec.
    public let note: String

    /// The engine configuration of the row.
    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: inputMethod, toneStyle: style)
    }

    /// The input method with the row's Telex options.
    public var inputMethod: InputMethod {
        switch method {
        case .vni: return .vni
        case .telex:
            return .telex(
                TelexOptions(standaloneW: options != "standalone w off", bracketKeys: options == "bracket keys on"))
        }
    }

    /// The events to send: one key per character, `⌫` as Backspace.
    public var events: [EngineEvent] { SpecExamples.events(typing: keys) }
}

/// A commit-decision example of spec 13.9, 13.9.1 and 13.9.2 (B001-B072 with the lettered rows B035a-B035h, B064a
/// and B064b).
public struct CommitDecisionExample: Sendable, Hashable {
    /// Whether the commit kept, restored or left the token unchanged.
    public enum Outcome: String, Sendable, Hashable { case kept, restored, unchanged }

    /// The row identifier of the spec (W001, B001, E01).
    public let id: String
    /// The keys typed, before the boundary.
    public let keys: String
    /// The boundary key that ends the token (Space for the 13.9 rows).
    public let boundary: Character
    /// Telex or VNI.
    public let method: FixtureMethod
    /// The language of the run before the row (8.3).
    public let previous: PreviousToken
    /// The app context of the row (8.6).
    public let context: AppContext
    /// Text after the boundary key, boundary included (`text,`, `dzậy `, `text\n`).
    public let expectedText: String
    /// The committed token without the boundary key.
    public let committed: String
    /// The rule column verbatim.
    public let ruleText: String
    /// `L0` ... `L11` (derived by the extractor, see the file header).
    public let ruleCode: String
    /// The outcome named by the row's rule column.
    public let outcome: Outcome

    /// The engine configuration of the row.
    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: method == .vni ? .vni : .telex(TelexOptions()), appContext: context)
    }

    /// The keys of the row's seed token (13.9 "Previous token") in the row's method: `việt` is typed `vie65t`
    /// in VNI, where `vieejt` would stay as typed. Nil for `none`.
    public var seedKeys: String? {
        guard method == .vni, previous == .vietnamese else { return previous.seedKeys }
        return "vie65t"
    }

    /// Keys of the example followed by the boundary key (no seed token).
    public var events: [EngineEvent] { SpecExamples.events(typing: keys) + [.key(KeyInput(boundary))] }

    /// The decision this row names, mapped onto the public `CommitDecision` (12.2). `L0` maps to
    /// `.kept(.unchanged)`; `L11` to `ambiguityTable`, `defaultVietnamese` or `techList` by its wording.
    public var expectedDecision: CommitDecision? {
        let rule: CommitRule
        switch ruleCode {
        case "L0": rule = .unchanged
        case "L1": rule = .userChoice
        case "L2": rule = .userList
        case "L3": rule = .abbreviation
        case "L3b": rule = .camelCase
        case "L4": rule = .escape
        case "L5": rule = .invalid
        case "L6": rule = .extendedSpelling
        case "L7": rule = .notEnglish
        case "L8": rule = .notAttested
        case "L9": rule = .codeContext
        case "L10": rule = .englishRun
        case "L11":
            if ruleText.containsText("ambiguity row") {
                rule = .ambiguityTable
            } else if ruleText.containsText("default vi") {
                rule = .defaultVietnamese
            } else if ruleText.containsText("tech") {
                rule = .techList
            } else {
                return nil
            }
        default: return nil
        }
        return outcome == .restored ? .restored(rule) : .kept(rule)
    }
}

/// A restore-toggle example of spec 13.10 (E01-E08 and E02b).
public struct RestoreToggleExample: Sendable, Hashable {
    /// The action expected for the row's last event.
    public enum Action: String, Sendable, Hashable { case edit, passThrough }

    /// The row identifier of the spec (W001, B001, E01).
    public let id: String
    /// Telex or VNI.
    public let method: FixtureMethod
    /// The events of the row.
    public let events: [EngineEvent]
    /// Display of the active token after the last event (empty when there is none).
    public let expectedActive: String
    /// What the last toggle returns.
    public let lastAction: Action
    /// The events column as written in the spec.
    public let eventsText: String
    /// The result column as written in the spec.
    public let resultText: String

    /// The engine configuration of the row.
    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: method == .vni ? .vni : .telex(TelexOptions()))
    }
}

/// One line of `commit-fixtures.tsv`.
public struct CommitFixtureRow: Sendable, Hashable {
    /// The list the value belongs to (`english`, `techAlways`, `techCodeOnly`, `unattested`, `ambiguity`).
    public let kind: String
    /// The word or raw keys.
    public let value: String
    /// The display of an ambiguity row; empty for the other lists.
    public let display: String
    /// The decision of an ambiguity row (`vi` / `en`); empty for the other lists.
    public let decision: String
}

/// Loaders for the corpus files extracted from the spec by `Scripts/extract-spec-examples.py`.
/// They take the file text so that callers decide how to read files (the test target uses its
/// resource bundle).
public enum SpecExamples {
    /// The 13.8 worked examples, extracted by `Scripts/extract-spec-examples.py`.
    public static let workedExamplesFile = "worked-examples.tsv"
    /// The 13.9 and 13.9.1 commit examples.
    public static let commitDecisionsFile = "commit-decisions.tsv"
    /// The 13.10 restore-toggle examples.
    public static let restoreToggleFile = "restore-toggle.tsv"
    /// The 13.9 fixture word lists.
    public static let commitFixturesFile = "commit-fixtures.tsv"

    /// One `.key` per character; `⌫` becomes `.backspace`.
    public static func events(typing keys: String) -> [EngineEvent] {
        keys.map { $0 == "⌫" ? .backspace : .key(KeyInput($0)) }
    }

    /// Parses the 13.8 worked examples.
    public static func workedExamples(tsv text: String) throws -> [WorkedExample] {
        let table = try TSVTable(name: workedExamplesFile, text: text)
        return try table.rows.map { row in
            WorkedExample(
                id: row["id"], group: row["group"], method: try method(row, table), style: try style(row, table),
                options: row["options"], keys: row["keys"], expected: row["expected"], note: row["note"])
        }
    }

    /// Parses the 13.9 and 13.9.1 commit examples.
    public static func commitDecisions(tsv text: String) throws -> [CommitDecisionExample] {
        let table = try TSVTable(name: commitDecisionsFile, text: text)
        return try table.rows.map { row in
            guard row["boundary"].count == 1, let boundary = row["boundary"].first else {
                throw FixtureError(file: table.name, line: row.line, reason: "boundary must be one character")
            }
            guard let previous = PreviousToken(rawValue: row["previous"]) else {
                throw FixtureError(
                    file: table.name, line: row.line, reason: "unknown previous token \(row["previous"])")
            }
            guard let outcome = CommitDecisionExample.Outcome(rawValue: row["outcome"]) else {
                throw FixtureError(file: table.name, line: row.line, reason: "unknown outcome \(row["outcome"])")
            }
            let context: AppContext
            switch row["context"] {
            case "general": context = .general
            case "code": context = .code
            default: throw FixtureError(file: table.name, line: row.line, reason: "unknown context \(row["context"])")
            }
            return CommitDecisionExample(
                id: row["id"], keys: row["keys"], boundary: boundary, method: try method(row, table),
                previous: previous,
                context: context, expectedText: row["expected_text"], committed: row["committed"],
                ruleText: row["rule_text"], ruleCode: row["rule_code"], outcome: outcome)
        }
    }

    /// Parses the 13.10 restore-toggle examples.
    public static func restoreToggles(tsv text: String) throws -> [RestoreToggleExample] {
        let table = try TSVTable(name: restoreToggleFile, text: text)
        return try table.rows.map { row in
            var events: [EngineEvent] = []
            for token in row["events"].split(separator: " ") {
                switch token {
                case "toggle": events.append(.restoreToggle)
                case "backspace": events.append(.backspace)
                case "space": events.append(.key(KeyInput(" ")))
                default:
                    guard token.hasPrefix("keys:") else {
                        throw FixtureError(file: table.name, line: row.line, reason: "unknown event \(token)")
                    }
                    events += Self.events(typing: String(token.dropFirst(5)))
                }
            }
            guard let action = RestoreToggleExample.Action(rawValue: row["last_action"]) else {
                throw FixtureError(file: table.name, line: row.line, reason: "unknown action \(row["last_action"])")
            }
            return RestoreToggleExample(
                id: row["id"], method: try method(row, table), events: events, expectedActive: row["expected_active"],
                lastAction: action, eventsText: row["events_text"], resultText: row["result_text"])
        }
    }

    /// Parses the 13.9 fixture word lists.
    public static func commitFixtures(tsv text: String) throws -> [CommitFixtureRow] {
        let table = try TSVTable(name: commitFixturesFile, text: text)
        return table.rows.map {
            CommitFixtureRow(kind: $0["kind"], value: $0["value"], display: $0["display"], decision: $0["decision"])
        }
    }

    private static func method(_ row: TSVTable.Row, _ table: TSVTable) throws -> FixtureMethod {
        guard let method = FixtureMethod(rawValue: row["method"]) else {
            throw FixtureError(file: table.name, line: row.line, reason: "unknown method \(row["method"])")
        }
        return method
    }

    private static func style(_ row: TSVTable.Row, _ table: TSVTable) throws -> ToneStyle {
        switch row["style"] {
        case "trad": return .traditional
        case "modern": return .modern
        default: throw FixtureError(file: table.name, line: row.line, reason: "unknown style \(row["style"])")
        }
    }
}
