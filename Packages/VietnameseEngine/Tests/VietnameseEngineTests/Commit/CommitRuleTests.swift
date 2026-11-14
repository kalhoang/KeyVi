// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Types keys in the notation of `KeyNotation` through a driver with the 13.9 fixture resources.
enum Committing {
    static let fixtures = SpecFixtures.commitResources()

    static func driver(
        _ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(), resources: Resources = fixtures
    ) throws -> EngineDriver {
        var driver = EngineDriver(configuration: configuration, resources: resources)
        try driver.send(KeyNotation.events(keys))
        return driver
    }

    /// The field after typing `keys`.
    static func text(
        _ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(), resources: Resources = fixtures
    ) throws -> String {
        try driver(keys, configuration, resources: resources).field.string
    }

    /// The decision reported by the last event.
    static func decision(
        _ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(), resources: Resources = fixtures
    ) throws -> CommitDecision? {
        try driver(keys, configuration, resources: resources).outputs.last?.decision
    }
}

/// Section 8.1 rule by rule, beyond the 13.9 rows (ENG-R801 to ENG-R803, ENG-R861).
@Suite("Commit rules L0-L11 (8.1)")
struct CommitRuleTests {
    @Test func l0NothingTransformed() throws {
        let driver = try Committing.driver("nam ")
        #expect(driver.field.string == "nam " && driver.outputs.last?.decision == .kept(.unchanged))
        #expect(driver.outputs.last?.action == .passThrough)
    }

    @Test func l1UserChoiceWithLearningSignals() throws {
        // ENG-R861: user-restored where the rules alone keep -> preferredRaw.
        var driver = try Committing.driver("vieejt⎋ ")
        #expect(driver.field.string == "vieejt " && driver.outputs.last?.decision == .restored(.userChoice))
        #expect(driver.outputs.last?.learning == .preferredRaw(raw: "vieejt"))
        // User-restored where the rules alone restore too (L5): no signal.
        driver = try Committing.driver("text⎋ ")
        #expect(driver.field.string == "text " && driver.outputs.last?.decision == .restored(.userChoice))
        #expect(driver.outputs.last?.learning == nil)
        // The signal carries the lowercased raw keys, the key of the user lists (ENG-R860).
        driver = try Committing.driver("Vieejt⎋,")
        #expect(driver.field.string == "Vieejt," && driver.outputs.last?.learning == .preferredRaw(raw: "vieejt"))
        // User-kept where the rules alone keep (`tiêng` is valid, `tieeng` not English): no signal.
        driver = try Committing.driver("tieengs⎋⌫⎋ ")
        #expect(driver.field.string == "tiêng " && driver.outputs.last?.decision == .kept(.userChoice))
        #expect(driver.outputs.last?.learning == nil)
    }

    @Test func l2UserLists() throws {
        let keepRaw = SpecFixtures.commitResources(userKeepRaw: ["vieejt"])
        #expect(try Committing.text("Vieejt ", resources: keepRaw) == "Vieejt ")
        #expect(try Committing.decision("vieejt ", resources: keepRaw) == .restored(.userList))
        let keepVietnamese = SpecFixtures.commitResources(userKeepVietnamese: ["text"])
        #expect(try Committing.text("text ", resources: keepVietnamese) == "tẽt ")
        #expect(try Committing.decision("text ", resources: keepVietnamese) == .kept(.userList))
        // In both lists: keep-as-typed is listed first (8.1 table).
        let both = SpecFixtures.commitResources(userKeepRaw: ["text"], userKeepVietnamese: ["text"])
        #expect(try Committing.decision("text ", resources: both) == .restored(.userList))
        // L1 comes before L2.
        #expect(try Committing.decision("text⎋⌫t⎋ ", resources: keepVietnamese) == .kept(.userChoice))
    }

    @Test func l3Abbreviations() throws {
        // ENG-R840, REG-17.
        for (keys, text) in [("ddc", "đc"), ("DDL", "ĐL"), ("DDHQG", "ĐHQG"), ("DDBSCL", "ĐBSCL"), ("ddt", "đt")] {
            let driver = try Committing.driver(keys + " ")
            #expect(driver.field.string == text + " ", "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(.abbreviation), "\(keys)")
        }
        // Reading (decision 0103): with an escape, L4 decides. `www` restores (ENG-T12), `ddd` keeps `dd`.
        #expect(try Committing.text("www ") == "www ")
        #expect(try Committing.decision("www ") == .restored(.escape))
        #expect(try Committing.text("ddd ") == "dd ")
        #expect(try Committing.decision("ddd ") == .kept(.escape))
        #expect(try Committing.text("d99 ", EngineConfiguration(inputMethod: .vni)) == "d9 ")
    }

    @Test func l3bCamelCase() throws {
        // ENG-R904: `useState` shows `ueState` while typing and commits as typed.
        let driver = try Committing.driver("useState ")
        #expect(driver.field.string == "useState " && driver.outputs.last?.decision == .restored(.camelCase))
        // Camel case that composed nothing is L0.
        #expect(try Committing.decision("iPhone ") == .kept(.unchanged))
    }

    @Test func l4ToL11() throws {
        #expect(try Committing.decision("password ") == .restored(.escape))
        #expect(try Committing.decision("nhaamff ") == .kept(.escape))  // C `nhâmf`, R not English
        #expect(try Committing.text("nhaamff ") == "nhâmf ")
        #expect(try Committing.decision("text ") == .restored(.invalid))
        #expect(try Committing.decision("zoom ") == .restored(.extendedSpelling))
        #expect(try Committing.decision("dzoo ") == .kept(.extendedSpelling))
        #expect(try Committing.decision("tets ") == .kept(.notEnglish))
        #expect(try Committing.decision("does ") == .restored(.notAttested))
        #expect(try Committing.decision("tar ", EngineConfiguration(appContext: .code)) == .restored(.codeContext))
        #expect(try Committing.decision("and this ") == .restored(.englishRun))
        #expect(try Committing.decision("test ") == .restored(.ambiguityTable))
        #expect(try Committing.decision("this ") == .kept(.ambiguityTable))
        #expect(try Committing.decision("tar ") == .kept(.defaultVietnamese))
        // L11 without a row: a tech-always word that is an attested syllable restores.
        let tech = Resources(
            english: WordSet([]), techAlways: WordSet(["mas"]), techCodeOnly: WordSet([]),
            attestedSyllables: WordSet(SpecFixtures.attestedSyllables), ambiguity: [:], userKeepRaw: WordSet([]),
            userKeepVietnamese: WordSet([]))
        #expect(try Committing.text("mas ", resources: tech) == "mas ")
        #expect(try Committing.decision("mas ", resources: tech) == .restored(.techList))
    }

    @Test func emptyResourcesNeedNoDownload() throws {
        // ENG-R106, REG-03: auto restore works without any data for invalid syllables.
        for word in ["text", "user", "wifi", "USB", "case", "data", "verbose"] {
            #expect(try Committing.text(word + " ", resources: .empty) == word + " ", "\(word)")
        }
    }

    @Test func autoRestoreOff() throws {
        // ENG-R802: L3b to L11 never restore; the rule that matched still names itself.
        let off = EngineConfiguration(autoRestore: false)
        for (keys, text, rule) in [
            ("text ", "tẽt ", CommitRule.invalid), ("test ", "tét ", .ambiguityTable),
            ("password ", "pasword ", .escape),
            ("useState ", "ueState ", .camelCase), ("zoom ", "zôm ", .extendedSpelling),
            ("does ", "dóe ", .notAttested),
        ] {
            let driver = try Committing.driver(keys, off)
            #expect(driver.field.string == text, "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(rule), "\(keys)")
        }
        // L1 and L2 still apply.
        #expect(try Committing.text("vieejt⎋ ", off) == "vieejt ")
        let keepRaw = SpecFixtures.commitResources(userKeepRaw: ["vieejt"])
        #expect(try Committing.text("vieejt ", off, resources: keepRaw) == "vieejt ")
        #expect(try Committing.decision("vieejt ", off, resources: keepRaw) == .restored(.userList))
    }

    @Test func restoreIsAnEditThenTheBoundaryKey() throws {
        // ENG-R803.
        let driver = try Committing.driver("text")
        var session = driver.session
        let output = session.handle(.key(KeyInput(";")))
        #expect(
            output.action == .edit(TextEdit(deleteCount: 2, deleteUTF16Count: 2, insert: "ext"), thenPassThrough: true))
        #expect(output.composingText.isEmpty && session.state.activeDisplay.isEmpty)
    }

    @Test func openHornPairIsWrittenUoAtCommit() throws {
        // ENG-R532: `thưở` + space -> `thuở`, `hươ` + comma -> `huơ`, as an edit before the boundary.
        var driver = try Committing.driver("thuowr")
        #expect(driver.field.string == "thưở")
        let output = try driver.send(.key(KeyInput(" ")))
        #expect(driver.field.string == "thuở ")
        #expect(
            output.action == .edit(TextEdit(deleteCount: 2, deleteUTF16Count: 2, insert: "uở"), thenPassThrough: true))
        #expect(try Committing.text("huow,") == "huơ,")
        #expect(try Committing.text("HUOW ") == "HUƠ ")
        // A reset commits nothing, so no edit is made (ENG-R532, ENG-R831).
        driver = try Committing.driver("thuowr")
        let reset = try driver.send(.reset(.cursorMoved))
        #expect(reset.action == .passThrough && driver.field.string == "thưở" && reset.decision == nil)
    }

    @Test func noMidWordRestore() throws {
        // ENG-R830: decisions only at a boundary.
        let driver = try Committing.driver("text")
        #expect(driver.field.string == "tẽt" && driver.outputs.allSatisfy { $0.decision == nil })
    }

    @Test func firstWordAfterFocusIsTreatedLikeAnyOther() throws {
        // ENG-R832, ENG-R1012, REG-18.
        #expect(try Committing.text("⟲verbose ") == "verbose ")
        var driver = try Committing.driver("vieejt ")
        try driver.send(.reset(.focusChanged))
        try driver.send(KeyNotation.events("verbose "))
        #expect(driver.field.string == "việt verbose ")
    }

    @Test func apostropheAndHyphenAreBoundaries() throws {
        // ENG-R911, ENG-R333: `don't` is `don`, `'`, `t`; `M'Đrắk` is `M`, `'`, `Đrắk`, each composed alone.
        #expect(try Committing.text("don't ") == "don't ")
        #expect(try Committing.text("M'DDrawsk ") == "M'Đrắk ")
        #expect(try Committing.text("DDawsk R'laaps ") == "Đắk R'lấp ")
        // `gar` composes `gả` in Telex; doubling the tone key keeps the `r` (ENG-R440).
        #expect(try Committing.text("Cuw M'gar ") == "Cư M'gả ")
        #expect(try Committing.text("Cuw M'garr ") == "Cư M'gar ")
        #expect(try Committing.text("vieejt-nam ") == "việt-nam ")
    }

    @Test func boundaryWithoutTokenHasNoDecision() throws {
        let driver = try Committing.driver("vieejt  ")
        #expect(driver.outputs.last?.decision == nil && driver.outputs.last?.action == .passThrough)
    }
}

/// ENG-R823: the language of committed tokens and the English run. Amended by the product owner on
/// 14/11/2026 (REG-32): the run is English when the previous three committed tokens of the run hold an
/// English token and no Vietnamese one, and a token kept Vietnamese by rule L11 is neutral.
@Suite("Commit: English run (8.3)")
struct EnglishRunTests {
    @Test func englishTokenAndNoVietnameseTokenInThePreviousThree() throws {
        #expect(try Committing.text("and this ") == "and this ")  // en
        #expect(try Committing.text("vieejt this ") == "việt thí ")  // vi
        #expect(try Committing.text("and vieejt this ") == "and việt thí ")
        // REG-32: a Vietnamese token anywhere in the window keeps the run Vietnamese, also behind English ones.
        #expect(try Committing.text("vieejt and this ") == "việt and thí ")
        #expect(try Committing.text("vieejt text user this ") == "việt text user thí ")
        // Three English tokens push it out of the window.
        #expect(try Committing.text("vieejt and text user this ") == "việt and text user this ")
        // Neutral tokens (`the`, `a`, digits, words outside the lexicon) are evidence of neither language.
        #expect(try Committing.text("and the a this ") == "and the a this ")
        #expect(try Committing.text("the a this ") == "the a thí ")
        // Only the previous three tokens count.
        #expect(try Committing.text("and nam nam nam this ") == "and nam nam nam thí ")
        #expect(try Committing.text("and nam nam this ") == "and nam nam this ")
        // Restored tokens are English (`text` restored by L5).
        #expect(try Committing.text("text this ") == "text this ")
        // The spec's example: `this is the best car` in an English run.
        #expect(try Committing.text("and this is the best car ") == "and this is the best car ")
    }

    @Test("REG-32: a collision after an English loanword in a Vietnamese sentence stays Vietnamese")
    func loanwordInAVietnameseSentence() throws {
        #expect(try Committing.text("dduwowcj as.") == "được á.")
        #expect(try Committing.text("treen server been ") == "trên server bên ")
        #expect(try Committing.text("guwir file car ") == "gửi file cả ")
        #expect(try Committing.text("cungx tricky as.") == "cũng tricky á.")
        #expect(try Committing.decision("cungx tricky as.") == .kept(.ambiguityTable))
        // At the start of a message only English is in the window.
        #expect(try Committing.text("tricky as ") == "tricky as ")
        #expect(try Committing.decision("tricky as ") == .restored(.englishRun))
    }

    @Test("ENG-R823 known cost: a collision within three tokens after a switch to English stays Vietnamese")
    func switchFromVietnameseToEnglish() throws {
        // `nghĩ` is still in the window of `car`; the earlier rule (nearest non-neutral token) restored it.
        #expect(try Committing.text("tooi nghix the best car ") == "tôi nghĩ the best cả ")
        // One more English token and the Vietnamese one has left the window.
        #expect(try Committing.text("tooi nghix the best text car ") == "tôi nghĩ the best text car ")
    }

    @Test func tokensKeptByTheAmbiguityTableAreNeutral() throws {
        // `thí` kept by its `vi` row and `tả` kept by the unreviewed default (L11) are evidence of neither
        // language, so the English `is` after them makes the run English.
        #expect(try Committing.text("this is as ") == "thí is as ")
        #expect(try Committing.text("This is as ") == "Thí is as ")
        #expect(try Committing.text("tar is as ") == "tả is as ")
        // ENG-R824: the first word is not corrected afterwards.
        #expect(try Committing.text("this is the best car ") == "thí is the best car ")
        #expect(try Committing.text("I think this is as ") == "I think this is as ")
    }

    @Test func theUsersVietnameseChoicesAreVietnameseEvidence() throws {
        // L2: the keep-Vietnamese list is the user's choice, not the ambiguity table.
        let resources = SpecFixtures.commitResources(userKeepVietnamese: ["car"])
        #expect(try Committing.text("car is as ", resources: resources) == "cả is á ")
        // L1: `test` re-opened in its restored state and toggled to `tét` is user-kept (ENG-R704).
        #expect(try Committing.text("test ⌫⎋ is as ") == "tét is á ")
    }

    @Test func languageOfACommittedToken() {
        let resources = Committing.fixtures
        func language(_ text: String, _ decision: CommitDecision) -> TokenLanguage {
            TokenLanguage.of(committed: CommittedTextFacts(text), decision: decision, resources: resources)
        }
        #expect(language("thí", .kept(.ambiguityTable)) == .neutral)
        #expect(language("tả", .kept(.defaultVietnamese)) == .neutral)
        #expect(language("cả", .kept(.userList)) == .vietnamese)
        #expect(language("tét", .kept(.userChoice)) == .vietnamese)
        #expect(language("việt", .kept(.notEnglish)) == .vietnamese)
        #expect(language("this", .restored(.englishRun)) == .english)
        #expect(language("test", .restored(.ambiguityTable)) == .english)
        #expect(language("and", .kept(.unchanged)) == .english)
        #expect(language("the", .kept(.unchanged)) == .neutral)
        #expect(language("nam", .kept(.unchanged)) == .neutral)
    }

    @Test func windowRule() {
        func isEnglishRun(_ languages: [TokenLanguage]) -> Bool {
            var window = RecentLanguages()
            for language in languages { window.push(language) }
            return window.isEnglishRun
        }
        #expect(!isEnglishRun([]))
        #expect(isEnglishRun([.english]))
        #expect(!isEnglishRun([.neutral, .neutral, .neutral]))
        #expect(!isEnglishRun([.vietnamese, .english]))
        #expect(!isEnglishRun([.english, .vietnamese]))
        #expect(!isEnglishRun([.vietnamese, .english, .english]))
        #expect(isEnglishRun([.english, .neutral, .neutral]))
        #expect(!isEnglishRun([.english, .neutral, .neutral, .neutral]))
        #expect(isEnglishRun([.vietnamese, .english, .english, .english]))
        #expect(isEnglishRun([.vietnamese, .neutral, .english, .neutral]))
    }

    @Test func boundaryCharactersAreNotTokens() throws {
        #expect(try Committing.text("and, (this) ") == "and, (this) ")
    }

    @Test func runContinuesAcrossReturnButNotAcrossReset() throws {
        // A run is the tokens since the last reset (spec 0); Return and Tab clear the history only.
        #expect(try Committing.text("and\nthis ") == "and\nthis ")
        #expect(try Committing.text("and\tthis ") == "and\tthis ")
        #expect(try Committing.text("and ⟲this ") == "and thí ")
    }

    @Test func reopeningATokenRemovesItsLanguage() throws {
        // `and` is re-opened and deleted: only the neutral `nam` is left in the window.
        #expect(try Committing.text("nam and ⌫⌫⌫⌫this ") == "nam thí ")
        // Re-committing the re-opened token restores its language.
        #expect(try Committing.text("nam and ⌫ this ") == "nam and this ")
    }

    @Test func macroExpansionsAreNeutralOrVietnamese() throws {
        let macros = try MacroTable([
            .init(trigger: "@@", expansion: "kal@example.com"), .init(trigger: "vn", expansion: "Việt Nam"),
        ])
        let resources = SpecFixtures.commitResources(macros: macros)
        #expect(try Committing.text("and @@ this ", resources: resources) == "and kal@example.com this ")
        #expect(try Committing.text("and vn this ", resources: resources) == "and Việt Nam thí ")
    }
}
