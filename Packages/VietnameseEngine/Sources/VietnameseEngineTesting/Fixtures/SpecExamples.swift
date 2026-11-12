// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// Method column of the spec tables.
public enum FixtureMethod: String, Sendable, Hashable {
    case telex = "Telex"
    case vni = "VNI"
}

/// Language of the previous token in a commit example (13.9 "Previous token", 8.3).
public enum PreviousToken: String, Sendable, Hashable {
    case none, vietnamese = "vi", english = "en"

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

/// A worked composition example of spec 13.8 (W001-W253).
public struct WorkedExample: Sendable, Hashable {
    public let id: String
    public let group: String
    public let method: FixtureMethod
    public let style: ToneStyle
    /// The options column verbatim (`-`, `bracket keys on`, `standalone w off`).
    public let options: String
    /// Keys typed; `⌫` is Backspace.
    public let keys: String
    /// Display after the last key, before any boundary.
    public let expected: String
    public let note: String

    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: inputMethod, toneStyle: style)
    }

    public var inputMethod: InputMethod {
        switch method {
        case .vni: return .vni
        case .telex:
            return .telex(TelexOptions(standaloneW: options != "standalone w off", bracketKeys: options == "bracket keys on"))
        }
    }

    /// The events to send: one key per character, `⌫` as Backspace.
    public var events: [EngineEvent] { SpecExamples.events(typing: keys) }
}

/// A commit-decision example of spec 13.9 and 13.9.1 (B001-B064).
public struct CommitDecisionExample: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable { case kept, restored, unchanged }

    public let id: String
    public let keys: String
    /// The boundary key that ends the token (Space for the 13.9 rows).
    public let boundary: Character
    public let method: FixtureMethod
    public let previous: PreviousToken
    public let context: AppContext
    /// Text after the boundary key, boundary included (`text,`, `dzậy `, `text\n`).
    public let expectedText: String
    /// The committed token without the boundary key.
    public let committed: String
    /// The rule column verbatim.
    public let ruleText: String
    /// `L0` ... `L11` (derived by the extractor, see the file header).
    public let ruleCode: String
    public let outcome: Outcome

    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: method == .vni ? .vni : .telex(TelexOptions()), appContext: context)
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
            if ruleText.contains("ambiguity row") {
                rule = .ambiguityTable
            } else if ruleText.contains("default vi") {
                rule = .defaultVietnamese
            } else if ruleText.contains("tech") {
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
    public enum Action: String, Sendable, Hashable { case edit, passThrough }

    public let id: String
    public let method: FixtureMethod
    public let events: [EngineEvent]
    /// Display of the active token after the last event (empty when there is none).
    public let expectedActive: String
    /// What the last toggle returns.
    public let lastAction: Action
    public let eventsText: String
    public let resultText: String

    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: method == .vni ? .vni : .telex(TelexOptions()))
    }
}

/// One line of `commit-fixtures.tsv`.
public struct CommitFixtureRow: Sendable, Hashable {
    public let kind: String
    public let value: String
    public let display: String
    public let decision: String
}

/// Loaders for the corpus files extracted from the spec by `Scripts/extract-spec-examples.py`.
/// They take the file text so that callers decide how to read files (the test target uses its
/// resource bundle).
public enum SpecExamples {
    public static let workedExamplesFile = "worked-examples.tsv"
    public static let commitDecisionsFile = "commit-decisions.tsv"
    public static let restoreToggleFile = "restore-toggle.tsv"
    public static let commitFixturesFile = "commit-fixtures.tsv"

    /// One `.key` per character; `⌫` becomes `.backspace`.
    public static func events(typing keys: String) -> [EngineEvent] {
        keys.map { $0 == "⌫" ? .backspace : .key(KeyInput($0)) }
    }

    public static func workedExamples(tsv text: String) throws -> [WorkedExample] {
        let table = try TSVTable(name: workedExamplesFile, text: text)
        return try table.rows.map { row in
            WorkedExample(
                id: row["id"], group: row["group"], method: try method(row, table), style: try style(row, table),
                options: row["options"], keys: row["keys"], expected: row["expected"], note: row["note"])
        }
    }

    public static func commitDecisions(tsv text: String) throws -> [CommitDecisionExample] {
        let table = try TSVTable(name: commitDecisionsFile, text: text)
        return try table.rows.map { row in
            guard row["boundary"].count == 1, let boundary = row["boundary"].first else {
                throw FixtureError(file: table.name, line: row.line, reason: "boundary must be one character")
            }
            guard let previous = PreviousToken(rawValue: row["previous"]) else {
                throw FixtureError(file: table.name, line: row.line, reason: "unknown previous token \(row["previous"])")
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
                id: row["id"], keys: row["keys"], boundary: boundary, method: try method(row, table), previous: previous,
                context: context, expectedText: row["expected_text"], committed: row["committed"],
                ruleText: row["rule_text"], ruleCode: row["rule_code"], outcome: outcome)
        }
    }

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
