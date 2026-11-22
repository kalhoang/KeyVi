// SPDX-License-Identifier: MPL-2.0
//
// REG-42 with the bundled data (the product owner's report of 23/11/2026 on 1.1.0-beta.1, Telex): typing
// `Thanks Giving bả với KT qua nhà ổng ở Ohio chơi`, the space after `bar` restored it (rule L10, the two English words
// before it make the run English) and Escape right after did not bring `bả` back: the toggle passed through (ENG-R703)
// and, in the host, the Escape that passed was a hard boundary, so the revision at the next Vietnamese word (RV4,
// ENG-R828) never came. The toggle right after such a restore now puts the composed form back (ENG-R706).

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R706 undo of a context restore with the bundled data (REG-42)")
struct ContextRestoreUndoRealDataTests {
    static let sentence = "Thanks Giving bar voiws KT qua nhaf oongr owr Ohio chowi"
    static let expected = "Thanks Giving bả với KT qua nhà ổng ở Ohio chơi"

    static func driver(_ keys: String, typoCorrection: Bool = false) throws -> EngineDriver {
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: typoCorrection), resources: try RealData.resources())
        try driver.send(KeyNotation.events(keys))
        return driver
    }

    @Test("REG-42: Escape right after `Thanks Giving bar ` gives `bả` back", arguments: [false, true])
    func productOwnerSentence(typoCorrection: Bool) throws {
        var driver = try Self.driver("Thanks Giving bar ", typoCorrection: typoCorrection)
        #expect(driver.field.string == "Thanks Giving bar ")
        #expect(driver.outputs.last?.decision == .restored(.englishRun))
        let undo = try driver.send(.restoreToggle)
        #expect(driver.field.string == "Thanks Giving bả ")
        guard case .edit(let edit, false) = undo.action else {
            Issue.record("the toggle is not answered with an edit that consumes the key")
            return
        }
        // The edit keeps the common prefix `b` (DisplayEdit) and types the boundary character again.
        #expect(edit.deleteCount == "ar ".count && edit.insert == "ả ")
        // The same learning as the Backspace-then-toggle path: ENG-R861 for the host's lists, ENG-R864 for the memory.
        #expect(undo.learning == .preferredVietnamese(raw: "bar"))
        #expect(
            undo.collisionSignals == [
                CollisionSignal(word: "bar", context: .afterEnglish, side: .vietnamese, strength: .strong)
            ])
        // ENG-R702: the second press passes through.
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        #expect(driver.field.string == "Thanks Giving bả ")
        try driver.send(KeyNotation.events(String(Self.sentence.dropFirst("Thanks Giving bar ".count))))
        #expect(driver.field.string == Self.expected)
    }

    @Test("REG-42: Escape then the rest of the sentence; typing on without Escape is as before", arguments: [false, true])
    func theWholeSentence(typoCorrection: Bool) throws {
        let withEscape = try Self.driver(
            "Thanks Giving bar \u{238B}voiws KT qua nhaf oongr owr Ohio chowi ", typoCorrection: typoCorrection)
        #expect(withEscape.field.string == Self.expected + " ")
        // Without Escape the next Vietnamese word revises `bar` (RV4, ENG-R828), as on 1.1.0-beta.1.
        let typedOn = try Self.driver(Self.sentence + " ", typoCorrection: typoCorrection)
        #expect(typedOn.field.string == Self.expected + " ")
        #expect(typedOn.outputs.compactMap(\.revision) == [.nextVietnamese])
    }

    @Test("ENG-R706, ENG-R704: Escape right after gives what Backspace then Escape gives, with the same signals")
    func sameAsBackspaceThenToggle() throws {
        let direct = try Self.driver("Thanks Giving bar \u{238B}")
        let viaBackspace = try Self.driver("Thanks Giving bar \u{232B}\u{238B} ")
        #expect(direct.field.string == viaBackspace.field.string)
        #expect(direct.outputs.compactMap(\.learning) == viaBackspace.outputs.compactMap(\.learning))
        let strong: (EngineDriver) -> [CollisionSignal] = { driver in
            driver.outputs.flatMap(\.collisionSignals).filter { $0.strength == .strong }
        }
        #expect(strong(direct) == strong(viaBackspace) && strong(direct).count == 1)
    }

    @Test("ENG-R706: a phrase restore is undone; restores the token alone decides are not")
    func phrasesAndTokenAloneRestores() throws {
        var phrase = try Self.driver("such as ")
        #expect(phrase.outputs.last?.decision == .restored(.phrase))
        try phrase.send(.restoreToggle)
        #expect(phrase.field.string == "such á ")
        // `best` is an `en` row and `the best` a phrase: the token alone is restored too, so Escape keeps its meaning.
        for keys in ["the best ", "this is the best car hello ", "tricky as hell ", "bar "] {
            var driver = try Self.driver(keys)
            #expect(try driver.send(.restoreToggle).action == .passThrough, "\(keys)")
            #expect(driver.field.string == (keys == "bar " ? "bả " : keys), "\(keys)")
        }
    }

    @Test("ENG-R706, ENG-R829: when the commit also revised the previous token, the revision is undone first")
    func revisionUndoFirst() throws {
        var driver = try Self.driver("has been ")
        #expect(driver.field.string == "has been " && driver.outputs.last?.revision == .phrase)
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "há been ")
        #expect(try driver.send(.restoreToggle).action == .passThrough)
    }

    @Test("ENG-R706, ENG-R829: no undo after Return, Tab or a non-ASCII boundary character")
    func noUndoAfterHardOrNonASCIIBoundaries() throws {
        for keys in ["Thanks Giving bar\n", "Thanks Giving bar\t", "Thanks Giving bar\u{2026}"] {
            var driver = try Self.driver(keys)
            let field = driver.field.string
            #expect(try driver.send(.restoreToggle).action == .passThrough, "\(keys.debugDescription)")
            #expect(driver.field.string == field)
        }
        var period = try Self.driver("Thanks Giving bar.")
        try period.send(.restoreToggle)
        #expect(period.field.string == "Thanks Giving bả.")
    }
}
