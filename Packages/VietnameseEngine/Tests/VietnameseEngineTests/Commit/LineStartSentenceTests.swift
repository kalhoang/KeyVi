// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The sentence condition of rule L9 (ENG-R850 as amended by the product owner on 16/11/2026, REG-36): shell commands
/// are typed in lowercase, so a capital first letter at the start of a line is itself a sign of a Vietnamese sentence.
/// In the code context L9 does not apply to a code-only word that (d) is the first token of its line, (e) is written in
/// sentence case, (f) is committed by a space and (g) is not on the capitalized code-word list; the rules after L9
/// decide it at its own commit, as in `general`. 13.9 fixtures: `tar` is code-only, English and has no ambiguity row,
/// so outside L9 it is kept by L11 (`defaultVietnamese`).
@Suite("L9 sentence condition: a code word in sentence case at a line start (ENG-R850, REG-36)")
struct LineStartSentenceTests {
    /// The terminal configuration: the rules turn `lookaheadRevision` off in every code-context app (PLT-R357).
    static let terminal = EngineConfiguration(appContext: .code, lookaheadRevision: false)
    /// Every combination of the two revision switches: the condition reads neither (ENG-R829).
    static let switches = [
        terminal, EngineConfiguration(appContext: .code),
        EngineConfiguration(appContext: .code, lookaheadRevision: false, lineStartRevision: false),
        EngineConfiguration(appContext: .code, lineStartRevision: false),
    ]

    /// The 13.9 fixtures with `tar` on the capitalized code-word list, standing for the bundled `host`.
    static var capitalized: Resources {
        var resources = Committing.fixtures
        resources.techCodeCapitalized = WordSet(["tar"])
        return resources
    }

    static func revisions(_ driver: EngineDriver) -> [RevisionReason] { driver.outputs.compactMap(\.revision) }

    @Test("Decided at the word's own commit by the rules after L9, whatever D29 and lookaheadRevision say")
    func decidedAtItsOwnCommit() throws {
        for configuration in Self.switches {
            let driver = try Committing.driver("Tar ", configuration)
            #expect(driver.field.string == "Tả ", "\(configuration)")
            #expect(driver.outputs.last?.decision == .kept(.defaultVietnamese), "\(configuration)")
            // REG-36: the product owner's sentence needs no revision.
            let sentence = try Committing.driver("Tar thuwr cais nayf ", configuration)
            #expect(sentence.field.string == "Tả thử cái này ", "\(configuration)")
            #expect(Self.revisions(sentence).isEmpty, "\(configuration)")
            #expect(try Committing.text("Tee ", configuration, resources: Self.tee) == "Tê ", "\(configuration)")
        }
        // The general context decides the same way (it never reaches L9).
        #expect(try Committing.decision("Tar ") == .kept(.defaultVietnamese))
    }

    /// `tee` as the bundled data has it: English, code-only, no ambiguity row, `tê` attested.
    static var tee: Resources {
        var resources = Committing.fixtures
        resources.english = WordSet(SpecFixtures.englishLexicon + ["tee"])
        resources.techCodeOnly = WordSet(SpecFixtures.techCodeOnly + ["tee"])
        return resources
    }

    @Test("Guard (d): the first token of its line, that is the engine's history is empty")
    func firstTokenOfTheLine() throws {
        for (keys, text) in [
            ("vieejt\nTar ", "việt\nTả "), ("vieejt\tTar ", "việt\tTả "), ("vieejt \u{27F2}Tar ", "việt Tả "),
            // A Backspace that empties the line starts it again.
            ("sudo \u{232B}\u{232B}\u{232B}\u{232B}\u{232B}Tar ", "Tả "),
        ] {
            let driver = try Committing.driver(keys, Self.terminal)
            #expect(driver.field.string == text, "\(keys.debugDescription)")
            #expect(driver.outputs.last?.decision == .kept(.defaultVietnamese), "\(keys.debugDescription)")
        }
        for (keys, text) in [
            (" Tar ", " Tar "),  // a space typed before it
            ("sudo Tar ", "sudo Tar "),  // after a code word
            ("and Tar ", "and Tar "),  // after an English word
            ("`Tar ", "`Tar "),  // after a code character
            ("anh.Tar ", "anh.Tar "),  // a code join
            ("tar Tar ", "tar Tar "),  // the second token of a line
        ] {
            let driver = try Committing.driver(keys, Self.terminal)
            #expect(driver.field.string == text, "\(keys.debugDescription)")
            #expect(driver.outputs.last?.decision == .restored(.codeContext), "\(keys.debugDescription)")
        }
    }

    @Test("Guard (e): sentence case, the first letter uppercase and every other letter lowercase, at least two letters")
    func sentenceCase() throws {
        for keys in ["TAR ", "TAr ", "tar "] {
            let driver = try Committing.driver(keys, Self.terminal)
            #expect(driver.field.string == keys, "\(keys.debugDescription)")
            #expect(driver.outputs.last?.decision == .restored(.codeContext), "\(keys.debugDescription)")
        }
        // Camel case (L3b, ENG-R904) restores these before L9; they are not sentence case either.
        for keys in ["tAr ", "taR "] { #expect(try Committing.text(keys, Self.terminal) == keys) }
        #expect(CommitPolicy.isSentenceCase("Tar") && CommitPolicy.isSentenceCase("Tee"))
        #expect(CommitPolicy.isSentenceCase("Ab") && CommitPolicy.isSentenceCase("Md5"))
        for raw in ["TAR", "TAr", "tar", "tAr", "T", "W", "", "5", "5a", "A5"] {
            #expect(!CommitPolicy.isSentenceCase(raw), "\(raw.debugDescription)")
        }
        // One letter is not a sentence case: a code-only `w` (Telex `W` shows `Ư`) keeps L9.
        var single = Committing.fixtures
        single.english = WordSet(SpecFixtures.englishLexicon + ["w"])
        single.techCodeOnly = WordSet(["w"])
        single.attestedSyllables = WordSet(SpecFixtures.allStandardSyllables.union(["ư"]))
        #expect(try Committing.text("W ", resources: single) == "Ư ")
        let driver = try Committing.driver("W ", Self.terminal, resources: single)
        #expect(driver.field.string == "W " && driver.outputs.last?.decision == .restored(.codeContext))
    }

    @Test("Guard (f): a space commits the word; any other key keeps L9 (`Tee-Object`, `Host:`, `Tar.`)")
    func committedByASpace() throws {
        for boundary in ["-", ".", ":", ",", ";", "!", "?", "/", "\"", "\n", "\t", "\u{00A0}", "\u{3000}", "`"] {
            let driver = try Committing.driver("Tar" + boundary, Self.terminal)
            #expect(driver.field.string == "Tar" + boundary, "\(boundary.debugDescription)")
            #expect(driver.outputs.last?.decision == .restored(.codeContext), "\(boundary.debugDescription)")
        }
        #expect(try Committing.text("Tar: thuwr ", Self.terminal) == "Tar: thử ")
        #expect(try Committing.text("Tar\nthuwr ", Self.terminal) == "Tar\nthử ")
    }

    @Test("Guard (g): a capitalized code word keeps L9, and RV5 with its own evidence only (`Host minh`)")
    func capitalizedCodeWords() throws {
        let resources = Self.capitalized
        let driver = try Committing.driver("Tar ", Self.terminal, resources: resources)
        #expect(driver.field.string == "Tar " && driver.outputs.last?.decision == .restored(.codeContext))
        for (keys, text) in [
            ("Tar anh ", "Tar anh "), ("Tar tay ", "Tar tay "), ("Tar anh\n", "Tar anh\n"), ("Tar thuwr.", "Tar thử."),
            ("Tar xf ", "Tar xf "),
        ] {
            let driver = try Committing.driver(keys, Self.terminal, resources: resources)
            #expect(driver.field.string == text, "\(keys.debugDescription)")
            #expect(Self.revisions(driver).isEmpty, "\(keys.debugDescription)")
        }
        // `Host nayf` gives `Hót này`: RV5's strict evidence, a Vietnamese-only letter kept by L7.
        let revised = try Committing.driver("Tar thuwr ", Self.terminal, resources: resources)
        #expect(revised.field.string == "Tả thử " && Self.revisions(revised) == [.lineVietnamese])
        let off = EngineConfiguration(appContext: .code, lookaheadRevision: false, lineStartRevision: false)
        #expect(try Committing.text("Tar thuwr ", off, resources: resources) == "Tar thử ")
        // The list is read only for the sentence condition: a lowercase word is the same with or without it.
        #expect(try Committing.text("tar thuwr ", Self.terminal, resources: resources) == "tả thử ")
    }

    @Test("Reason codes: the token gets the decision the rules after L9 give it, as in the general context")
    func reasonCodes() throws {
        var vietnameseRow = Committing.fixtures
        vietnameseRow.ambiguity["tar"] = .vietnamese
        #expect(try Committing.decision("Tar ", Self.terminal, resources: vietnameseRow) == .kept(.ambiguityTable))
        var englishRow = Committing.fixtures
        englishRow.ambiguity["tar"] = .english
        let english = try Committing.driver("Tar ", Self.terminal, resources: englishRow)
        #expect(english.field.string == "Tar " && english.outputs.last?.decision == .restored(.ambiguityTable))
        // An English run from the previous line: L10 restores it, as in the general context.
        let run = try Committing.driver("and\nTar ", Self.terminal)
        #expect(run.field.string == "and\nTar " && run.outputs.last?.decision == .restored(.englishRun))
        // The learned memory (L9c).
        var learned = vietnameseRow
        learned.collisionMemory = CollisionMemorySnapshot([.init(word: "tar", context: nil, choice: .english)])
        #expect(try Committing.decision("Tar ", Self.terminal, resources: learned) == .restored(.learned))
        // The user's keep-as-typed list (L2) still decides first.
        var keepRaw = Committing.fixtures
        keepRaw.userKeepRaw = WordSet(["tar"])
        #expect(try Committing.decision("Tar ", Self.terminal, resources: keepRaw) == .restored(.userList))
        // Auto restore off: L9 would keep anyway (ENG-R802), and so do the rules after it.
        let manual = EngineConfiguration(autoRestore: false, appContext: .code)
        #expect(try Committing.decision("Tar ", manual) == .kept(.defaultVietnamese))
        #expect(try Committing.decision("TAR ", manual) == .kept(.codeContext))
    }

    @Test("ENG-R823: the kept word is neutral, so the next code word is decided by L9 as after any neutral word")
    func language() throws {
        let driver = try Committing.driver("Tar ", Self.terminal)
        let token = try #require(driver.state.history.token(beforeNewest: 1))
        #expect(token.language == .neutral && token.decision == .kept(.defaultVietnamese))
        #expect(try Committing.text("Tar tar ", Self.terminal) == "Tả tar ")
        #expect(try Committing.text("Tar thuwr tar ", Self.terminal) == "Tả thử tả ")
        // An English word after it is decided by its own rules (the cost of an English line typed with a capital).
        #expect(try Committing.text("Tar test ", Self.terminal) == "Tả test ")
    }

    @Test("The restore key and a re-opened word behave as for any kept token")
    func restoreKeyAndReopening() throws {
        // The restore key on the composing word shows its keys, and the space commits them (L1 before L9, ENG-R701).
        let toggled = try Committing.driver("Tar\u{238B} ", Self.terminal)
        #expect(toggled.field.string == "Tar " && toggled.outputs.last?.decision == .restored(.userChoice))
        // Right after the commit there is no revision to undo and no active token: the key passes through (ENG-R703).
        var driver = try Committing.driver("Tar ", EngineConfiguration(appContext: .code))
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        #expect(driver.field.string == "Tả ")
        // Backspace over the space re-opens `Tả`; committed again by a space, the condition holds again, and by
        // another key it does not.
        let reopened = try Committing.driver("Tar \u{232B}", Self.terminal)
        #expect(reopened.field.string == "Tả" && reopened.state.activeRawKeys == "Tar")
        #expect(try Committing.text("Tar \u{232B} ", Self.terminal) == "Tả ")
        #expect(try Committing.text("Tar \u{232B}-", Self.terminal) == "Tar-")
    }
}
