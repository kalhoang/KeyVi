// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// RV5 of ENG-R828 (ENG-R850 as amended on 16/11/2026, REG-36): at the start of a line nothing stands before a
/// token, so rule L9 restores a code-only word there; once the next word shows the line is Vietnamese text, the
/// word takes the display the rules after L9 give it, as in the general context. 13.9 fixtures: `tar` is
/// code-only, English and has no ambiguity row, so outside L9 it is kept by L11 (`defaultVietnamese`). A word in
/// sentence case committed by a space (`Tar`) is not restored by L9 at the line start at all (ENG-R850 as amended by
/// the product owner on 16/11/2026, `LineStartSentenceTests`), so RV5 meets lowercase and all-caps words and the
/// capitalized code words.
@Suite("RV5: a code word at a line start, Vietnamese next (ENG-R828, ENG-R850, REG-36)")
struct LineStartRevisionTests {
    /// The terminal configuration: the rules turn `lookaheadRevision` off in every code-context app (PLT-R357).
    static let terminal = EngineConfiguration(appContext: .code, lookaheadRevision: false)
    static let code = EngineConfiguration(appContext: .code)

    static func revisions(_ driver: EngineDriver) -> [RevisionReason] { driver.outputs.compactMap(\.revision) }

    @Test("REG-36: `tar thuwr cais nayf` gives tả thử cái này, in the terminal configuration too")
    func productOwnerSentence() throws {
        for configuration in [Self.terminal, Self.code] {
            let driver = try Committing.driver("tar thuwr cais nayf ", configuration)
            #expect(driver.field.string == "tả thử cái này ")
            #expect(Self.revisions(driver) == [.lineVietnamese])
            #expect(try Committing.text("TAR thuwr ", configuration) == "TẢ thử ")
        }
    }

    @Test("ENG-R803: one edit covers the word, the space and the next word; the boundary key follows")
    func oneEdit() throws {
        let driver = try Committing.driver("tar thuwr ", Self.terminal)
        guard case .edit(let edit, true)? = driver.outputs.last?.action else {
            Issue.record("the revising commit is not an edit with pass-through")
            return
        }
        // The edit is minimal (ENG-R611): the shared `t` stays.
        #expect(edit.deleteCount == "ar thử".count && edit.insert == "ả thử")
        #expect(driver.outputs.last?.decision == .kept(.notEnglish))
        // ENG-R823: the revised token is neutral, keeps its L9 reason code and is never revised again.
        let revised = try #require(driver.state.history.token(beforeNewest: 3))
        #expect(revised.committedText == "tả" && revised.language == .neutral)
        #expect(revised.decision == .restored(.codeContext) && revised.collision.revision == .lineVietnamese)
        var window = RecentLanguages()
        for language in [TokenLanguage.neutral, .vietnamese] { window.push(language) }
        #expect(driver.state.recentLanguages == window)
        // The next code-only word is in Vietnamese text (ENG-R850).
        #expect(try Committing.text("tar thuwr tar ", Self.terminal) == "tả thử tả ")
    }

    @Test("A line starts at the start of the input, after Return, after Tab and after a reset")
    func lineStarts() throws {
        for (keys, text) in [
            ("vieejt\ntar thuwr ", "việt\ntả thử "), ("vieejt\ttar thuwr ", "việt\ttả thử "),
            ("vieejt \u{27F2}tar thuwr ", "việt tả thử "), ("tar thuwr\ntar thuwr ", "tả thử\ntả thử "),
            // The condition is the engine's empty history, so a Backspace that empties the line starts it again,
            // and so does a reset in the middle of a line (a click, a focus change), L9's own blind spot after a
            // reset (ENG-R850 known costs).
            ("sudo \u{232B}\u{232B}\u{232B}\u{232B}\u{232B}tar thuwr ", "tả thử "),
            ("sudo \u{27F2}tar thuwr ", "sudo tả thử "),
        ] {
            #expect(try Committing.text(keys, Self.terminal) == text, "\(keys.debugDescription)")
        }
    }

    @Test("Guard: the word is the first thing typed on its line")
    func notFirstOnTheLine() throws {
        for (keys, text) in [
            ("sudo tar thuwr ", "sudo tar thử "),  // after a code word
            ("and tar thuwr ", "and tar thử "),  // after an English word
            ("tar tar thuwr ", "tar tar thử "),  // the first `tar` is followed by a restored word
            ("vieejt `tar thuwr ", "việt `tar thử "),  // after a code character
            ("`tar thuwr ", "`tar thử "),  // a backquote before it on the line
            (" tar thuwr ", " tar thử "),  // a space typed before it
            ("anh.tar thuwr ", "anh.tar thử "),  // a code join
        ] {
            #expect(try Committing.text(keys, Self.terminal) == text, "\(keys.debugDescription)")
        }
    }

    @Test("Guard: the next word is Vietnamese evidence with a Vietnamese-only letter, kept by L7")
    func nextWordNotVietnamese() throws {
        for (keys, text) in [
            ("tar xf ", "tar xf "),  // an option
            ("tar test ", "tar test "),  // English
            // A lowercase word before a syllable typed unchanged: a host, user or branch name.
            ("tar anh ", "tar anh "),
            ("tar car ", "tar car "),  // a collision word, restored by the English run after `tar`
            ("tar Kroong ", "tar Krông "),  // Tier B (L6)
            ("tar ddc ", "tar đc "),  // no vowel (L3)
        ] {
            #expect(try Committing.text(keys, Self.terminal) == text, "\(keys.debugDescription)")
        }
    }

    @Test("Guard: the key that ends the next word is a space, Return, comma, ! or ?; never a file name character")
    func boundaryOfTheNextWord() throws {
        for boundary in [" ", "\n", ",", "!", "?"] {
            #expect(try Committing.text("tar thuwr" + boundary, Self.terminal) == "tả thử" + boundary)
        }
        for boundary in [".", "-", "/", "_", ":", ";", "\"", ")", "\t", "\u{00A0}", "~", "@", "*"] {
            let driver = try Committing.driver("tar thuwr" + boundary, Self.terminal)
            #expect(driver.field.string == "tar thử" + boundary, "\(boundary.debugDescription)")
            #expect(Self.revisions(driver).isEmpty, "\(boundary.debugDescription)")
        }
        #expect(try Committing.text("tar nhaatj-kys ", Self.terminal) == "tar nhật-ký ")
        #expect(try Committing.text("tar nhaatj.log ", Self.terminal) == "tar nhật.log ")
    }

    @Test("The case of the word never widens the evidence (the widening of 16/11/2026 was withdrawn)")
    func noWideningByCase() throws {
        // The product owner's rule of 16/11/2026 decides a word in sentence case at its own commit (ENG-R850), so
        // RV5 keeps its strict evidence for every word it meets: lowercase, all caps and the capitalized code words.
        var capitalized = Committing.fixtures
        capitalized.techCodeCapitalized = WordSet(["tar"])
        for (keys, text, resources) in [
            ("tar anh ", "tar anh ", Committing.fixtures), ("tar thuwr.", "tar thử.", Committing.fixtures),
            ("TAR anh ", "TAR anh ", Committing.fixtures), ("TAR thuwr.", "TAR thử.", Committing.fixtures),
            ("TAR tay\n", "TAR tay\n", Committing.fixtures),
            // `Host minh` in ~/.ssh/config: a syllable typed unchanged is a host name, a period a file name.
            ("Tar anh ", "Tar anh ", capitalized), ("Tar tay\n", "Tar tay\n", capitalized),
            ("Tar anh,", "Tar anh,", capitalized), ("Tar thuwr.", "Tar thử.", capitalized),
        ] {
            let driver = try Committing.driver(keys, Self.terminal, resources: resources)
            #expect(driver.field.string == text, "\(keys.debugDescription)")
            #expect(Self.revisions(driver).isEmpty, "\(keys.debugDescription)")
        }
        for (keys, text, resources) in [
            ("TAR thuwr ", "TẢ thử ", Committing.fixtures), ("TAR THUWR ", "TẢ THỬ ", Committing.fixtures),
            ("Tar thuwr ", "Tả thử ", capitalized), ("Tar thuwr!", "Tả thử!", capitalized),
        ] {
            let driver = try Committing.driver(keys, Self.terminal, resources: resources)
            #expect(driver.field.string == text, "\(keys.debugDescription)")
            #expect(Self.revisions(driver) == [.lineVietnamese], "\(keys.debugDescription)")
        }
    }

    @Test("Guard: the word is followed by exactly one space, and nothing happens between the two commits")
    func oneSpaceAndNothingBetween() throws {
        for (keys, text) in [
            ("tar  thuwr ", "tar  thử "), ("tar, thuwr ", "tar, thử "), ("tar -thuwr ", "tar -thử "),
            ("tar \u{27F2}thuwr ", "tar thử "),  // a reset
            ("tar  \u{232B}thuwr ", "tar thử "),  // a Backspace into the history
            ("tar thuwa\u{232B}r ", "tả thử "),  // a Backspace inside the next word is allowed
        ] {
            #expect(try Committing.text(keys, Self.terminal) == text, "\(keys.debugDescription)")
        }
    }

    @Test("Guard: the rules after L9 keep the Vietnamese display (never an `en` row, L10 or a learned English vote)")
    func generalDecisionKeeps() throws {
        var englishRow = Committing.fixtures
        englishRow.ambiguity["tar"] = .english
        #expect(try Committing.text("tar thuwr ", Self.terminal, resources: englishRow) == "tar thử ")
        // An English run from the previous line: L10 would restore `tar` in the general context too.
        #expect(try Committing.text("and\ntar thuwr ", Self.terminal) == "and\ntar thử ")
        #expect(try Committing.text("and\ntar thuwr ") == "and\ntar thử ")
        // The learned memory (L9c) decides as in the general context.
        var vietnameseRow = Committing.fixtures
        vietnameseRow.ambiguity["tar"] = .vietnamese
        var english = vietnameseRow
        english.collisionMemory = CollisionMemorySnapshot([.init(word: "tar", context: nil, choice: .english)])
        #expect(try Committing.text("tar thuwr ", Self.terminal, resources: english) == "tar thử ")
        var vietnamese = vietnameseRow
        vietnamese.collisionMemory = CollisionMemorySnapshot([
            .init(word: "tar", context: .sentenceStart, choice: .vietnamese)
        ])
        #expect(try Committing.text("tar thuwr ", Self.terminal, resources: vietnamese) == "tả thử ")
    }

    @Test("ENG-R829: D29 off (`lineStartRevision`), auto restore off or the general context: no RV5")
    func switches() throws {
        let off = EngineConfiguration(appContext: .code, lookaheadRevision: false, lineStartRevision: false)
        #expect(try Committing.text("tar thuwr cais nayf ", off) == "tar thử cái này ")
        let bothOff = EngineConfiguration(appContext: .code, lineStartRevision: false)
        #expect(try Committing.text("tar thuwr ", bothOff) == "tar thử ")
        // The sentence condition of L9 does not depend on the switch (ENG-R850).
        #expect(try Committing.text("Tar thuwr cais nayf ", off) == "Tả thử cái này ")
        // Auto restore off: L9 keeps `tả` (ENG-R802), so there is nothing to revise.
        let manual = EngineConfiguration(autoRestore: false, appContext: .code)
        let driver = try Committing.driver("tar thuwr ", manual)
        #expect(driver.field.string == "tả thử " && Self.revisions(driver).isEmpty)
        // The general context never reaches L9, so never RV5.
        let general = try Committing.driver("tar thuwr ")
        #expect(general.field.string == "tả thử " && Self.revisions(general).isEmpty)
    }

    @Test("ENG-R829: the toggle right after the revising commit gives the keys back; the next toggle passes through")
    func undo() throws {
        var driver = try Committing.driver("tar thuwr ", Self.code)
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "tar thử ")
        guard case .edit(_, false) = output.action else {
            Issue.record("the undo is not an edit that consumes the key")
            return
        }
        let undone = try #require(driver.state.history.token(beforeNewest: 3))
        #expect(undone.decision == .restored(.userChoice) && undone.collision.revision == nil)
        #expect(undone.language == .english)
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        try driver.send(KeyNotation.events("cais "))
        #expect(driver.field.string == "tar thử cái ")
    }

    @Test("A revised word re-opens with its Vietnamese display; re-committed, the line rules decide it again")
    func reopening() throws {
        // Backspace over `thử ` and the space re-opens `tả` (ENG-R1002).
        let driver = try Committing.driver(
            "tar thuwr \u{232B}\u{232B}\u{232B}\u{232B}\u{232B}", Self.terminal)
        #expect(driver.field.string == "tả" && driver.state.activeRawKeys == "tar")
        // Committed again at the line start, L9 restores it, and the next Vietnamese word revises it again.
        #expect(try Committing.text("tar thuwr \u{232B}\u{232B}\u{232B}\u{232B}\u{232B} ", Self.terminal) == "tar ")
        #expect(
            try Committing.text("tar thuwr \u{232B}\u{232B}\u{232B}\u{232B}\u{232B} thuwr ", Self.terminal)
                == "tả thử ")
    }
}
