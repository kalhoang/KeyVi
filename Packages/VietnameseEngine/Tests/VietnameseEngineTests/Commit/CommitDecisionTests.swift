// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.9, 13.9.1 and 13.9.2: every row B001-B072 (with the lettered rows B035a-B035h, B064a and B064b) with the
/// 13.9 fixture resources, checking the committed text and the rule that decided (ENG-R801), then the same rows
/// ended by every boundary key of section 9 (P0-3: the decision must not depend on which boundary key ended the
/// token). The 13.9.2 rows and the rows whose keys hold several tokens type a whole run of tokens (ENG-R823,
/// REG-32, ENG-R850); the rule is the one that decided the last token.
@Suite("Commit decisions B001-B072 (13.9, 13.9.1, 13.9.2)")
struct CommitDecisionTests {
    static let rows: [CommitDecisionExample] = {
        do {
            return try SpecExamples.commitDecisions(tsv: CorpusFiles.text(SpecExamples.commitDecisionsFile))
        } catch {
            Issue.record("cannot load \(SpecExamples.commitDecisionsFile): \(error)")
            return []
        }
    }()

    static let resources = SpecFixtures.commitResources()

    /// A boundary key event of the 9.2 table.
    struct Boundary: CustomStringConvertible, Sendable {
        let input: KeyInput
        let isHard: Bool
        var description: String { "\(input.character.debugDescription)\(input.fromKeypad ? " (keypad)" : "")" }
    }

    /// Every key classed as a boundary in 9.2 for `method` with default options: whitespace, every ASCII
    /// punctuation or symbol character (brackets included, the bracket option is off), Return and Tab
    /// (hard), keypad digits, Telex main-row digits, and letters outside A-Z.
    static func boundaries(for method: FixtureMethod) -> [Boundary] {
        var keys: [Boundary] = []
        for character in [" ", "\u{00A0}", "\u{2003}", "\u{3000}"] as [Character] {
            keys.append(Boundary(input: KeyInput(character), isHard: false))
        }
        for value in UInt8(0x21)...UInt8(0x7E) {
            let character = Character(Unicode.Scalar(value))
            guard !character.isLetter, !character.isNumber else { continue }
            keys.append(Boundary(input: KeyInput(character), isHard: false))
        }
        for character in ["\n", "\t", "\r", "\r\n"] as [Character] {
            keys.append(Boundary(input: KeyInput(character), isHard: true))
        }
        for digit in "0123456789" {
            keys.append(Boundary(input: KeyInput(digit, fromKeypad: true), isHard: false))
            if method == .telex { keys.append(Boundary(input: KeyInput(digit), isHard: false)) }
        }
        for character in ["é", "ß", "ư", "Đ", "ñ", "ạ"] as [Character] {
            keys.append(Boundary(input: KeyInput(character), isHard: false))
        }
        return keys
    }

    /// Types the seed token of the row (13.9 "Previous token"), the keys and `boundary`; returns the text
    /// the token and the boundary left and the boundary's output.
    static func run(_ row: CommitDecisionExample, boundary: KeyInput) throws -> (
        text: String, output: EngineOutput, driver: EngineDriver
    ) {
        var driver = EngineDriver(configuration: row.configuration, resources: resources)
        if let seed = row.seedKeys { try driver.type(seed + " ") }
        let prefix = driver.field.string
        try driver.type(row.keys)
        let output = try driver.send(.key(boundary))
        let text = String(driver.field.string.dropFirst(prefix.count))
        return (text, output, driver)
    }

    @Test func allRowsArePresent() {
        #expect(Self.rows.count == 82)
    }

    @Test(arguments: rows)
    func committedTextAndRule(_ row: CommitDecisionExample) throws {
        let (text, output, _) = try Self.run(row, boundary: KeyInput(row.boundary))
        #expect(text == row.expectedText, "\(row.id) \(row.keys): \(row.ruleText)")
        #expect(output.decision == row.expectedDecision, "\(row.id) \(row.keys): \(row.ruleText)")
        // ENG-R803: a restore is an edit followed by the boundary key; nothing else is swallowed.
        switch output.action {
        case .passThrough: break
        case .edit(_, let thenPassThrough): #expect(thenPassThrough, "\(row.id): the boundary key must follow the edit")
        }
    }

    @Test(arguments: rows)
    func sameDecisionAtEveryBoundaryKey(_ row: CommitDecisionExample) throws {
        // 13.9.1, P0-3, REG-29, REG-30: the same commit for every boundary key; the key reaches the app
        // after the edit, so the text is in order (Return after the edit: a chat app never sends the
        // unrestored text, B064).
        for boundary in Self.boundaries(for: row.method) {
            let (text, output, driver) = try Self.run(row, boundary: boundary.input)
            #expect(text == row.committed + String(boundary.input.character), "\(row.id) \(row.keys) + \(boundary)")
            #expect(output.decision == row.expectedDecision, "\(row.id) \(row.keys) + \(boundary)")
            if case .edit(_, let thenPassThrough) = output.action {
                #expect(thenPassThrough, "\(row.id) + \(boundary)")
            }
            // ENG-R912: Return and Tab clear the history after the commit; other boundaries keep it.
            if boundary.isHard {
                #expect(driver.state.historyCount == 0, "\(row.id) + \(boundary)")
            } else {
                let tokens = row.keys.split(separator: " ").count + (row.previous == .none ? 0 : 1)
                #expect(driver.state.historyCount == tokens, "\(row.id) + \(boundary)")
            }
        }
    }

    @Test func boundaryListCoversSection9() {
        let telex = Self.boundaries(for: .telex)
        // 4 whitespace + 32 ASCII punctuation/symbols + 4 hard + 10 keypad + 10 main-row + 6 letters.
        #expect(telex.count == 66)
        #expect(Self.boundaries(for: .vni).count == 56)
        let engine = Engine(configuration: EngineConfiguration(), resources: Self.resources)
        for boundary in telex {
            var session = Session(engine: engine)
            _ = session.handle(.key(KeyInput("a")))
            _ = session.handle(.key(boundary.input))
            #expect(session.state.activeDisplay.isEmpty, "\(boundary) must end the token")
        }
    }
}
