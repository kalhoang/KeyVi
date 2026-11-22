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

    @Test("REG-42: Escape then the rest of the sentence; typing on without Escape as before", arguments: [false, true])
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

    /// Common English words of the census of ENG-R706 (the `i_census` set of `Scripts/context-restore-measure`) and the
    /// text the toggle right after their English-run restore gives: each is a `vi` row of the ambiguity table that an
    /// English run restores (its `run` column is `en`), so Escape right after it is consumed.
    static let ordinaryWords: KeyValuePairs<String, String> = [
        "as": "á", "of": "ò", "if": "ì", "this": "thí", "there": "thể", "these": "thế", "here": "hể", "now": "nơ",
        "too": "tô", "us": "ú", "has": "há", "his": "hí", "its": "ít", "how": "hơ", "most": "mót", "must": "mút",
        "last": "lát", "been": "bên", "did": "đi", "away": "ây", "own": "ơn", "thus": "thú", "car": "cả", "bus": "bú",
        "box": "bõ", "mix": "mĩ", "six": "sĩ", "rest": "rét", "lost": "lót", "low": "lơ", "turn": "tủn", "tree": "trê",
    ]

    @Test("ENG-R706: after an English run, Escape right after an ordinary English word gives its Vietnamese form too")
    func ordinaryEnglishWordsAreCovered() throws {
        // The scope as built (ADR 0010 item 9): every restore of rule L10 whose token alone would stay Vietnamese.
        for (word, composed) in Self.ordinaryWords {
            var driver = try Self.driver("Thanks Giving \(word) ")
            #expect(driver.outputs.last?.decision == .restored(.englishRun), "\(word)")
            let undo = try driver.send(.restoreToggle)
            #expect(driver.field.string == "Thanks Giving \(composed) ", "\(word)")
            #expect(undo.learning == .preferredVietnamese(raw: word), "\(word)")
        }
        // The review's case: a writer of English who presses Escape right after `there` for another reason gets `thể`,
        // the learning of a Vietnamese choice and the strong signal (ENG-R861, ENG-R864); the second Escape passes.
        var driver = try Self.driver("I will be there ")
        #expect(driver.field.string == "I will be there ")
        let undo = try driver.send(.restoreToggle)
        #expect(driver.field.string == "I will be thể ")
        #expect(undo.learning == .preferredVietnamese(raw: "there"))
        #expect(
            undo.collisionSignals == [
                CollisionSignal(word: "there", context: .afterEnglish, side: .vietnamese, strength: .strong)
            ])
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        var sentenceEnd = try Self.driver("see you there.")
        try sentenceEnd.send(.restoreToggle)
        #expect(sentenceEnd.field.string == "see you thể.")
    }

    @Test("ENG-R706, ENG-R825: `tricky as.` is kept by rule L9a, so the toggle passes; `tricky as,` is undone")
    func boundaryParticleBeforeASentenceEnd() throws {
        // `as` is the boundary particle of the bundled data: before `.` or `?` rule L9a keeps `á` and there is no
        // restore to undo (13.10 row E11 uses `,`, where rule L10 restores it with the 13.9 fixtures and this data).
        for keys in ["tricky as.", "tricky as?"] {
            var driver = try Self.driver(keys)
            #expect(driver.outputs.last?.decision == .kept(.boundaryParticle), "\(keys)")
            let field = driver.field.string
            #expect(try driver.send(.restoreToggle).action == .passThrough, "\(keys)")
            #expect(driver.field.string == field, "\(keys)")
        }
        var comma = try Self.driver("tricky as,")
        #expect(comma.field.string == "tricky as," && comma.outputs.last?.decision == .restored(.englishRun))
        let undo = try comma.send(.restoreToggle)
        #expect(comma.field.string == "tricky á," && undo.learning == .preferredVietnamese(raw: "as"))
    }

    @Test("ENG-R706, ENG-R829: lookaheadRevision off still undoes; auto restore off restores nothing to undo")
    func switchesWithTheBundledData() throws {
        var noLookahead = EngineDriver(
            configuration: EngineConfiguration(lookaheadRevision: false, typoCorrection: false),
            resources: try RealData.resources())
        try noLookahead.send(KeyNotation.events("Thanks Giving bar "))
        #expect(noLookahead.outputs.last?.decision == .restored(.englishRun))
        try noLookahead.send(.restoreToggle)
        #expect(noLookahead.field.string == "Thanks Giving bả ")
        #expect(try noLookahead.send(.restoreToggle).action == .passThrough)
        var noRestore = EngineDriver(
            configuration: EngineConfiguration(autoRestore: false, typoCorrection: false),
            resources: try RealData.resources())
        try noRestore.send(KeyNotation.events("Thanks Giving bar "))
        #expect(noRestore.field.string == "Thanks Giving bả ")
        let toggle = try noRestore.send(.restoreToggle)
        #expect(toggle.action == .passThrough && toggle.learning == nil && toggle.collisionSignals.isEmpty)
        #expect(noRestore.field.string == "Thanks Giving bả ")
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
