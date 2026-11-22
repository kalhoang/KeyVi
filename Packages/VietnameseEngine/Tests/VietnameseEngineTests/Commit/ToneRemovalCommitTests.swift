// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Rule L4a of 8.1 (ENG-R411, REG-39), decided by the product owner on 18/11/2026 (Q9 of section 15): when the last key
/// of a token is a tone-removal key (Telex `z`, VNI `0`) that removed the tone or the letter marks, the commit keeps the
/// text shown unless the raw keys are English, as an escape does (L4). The first version decided such a token by the
/// rules after L4 like any other, so `dduwowngfzz` showed `duong` and Space restored `dduwowngfzz` (L5). A removal that
/// more letters follow belongs to a word typed through (`Amazon`: the `z` removes the circumflex the second `a` gave
/// the first), which the rules after L4a decide as before: kept anywhere in the token, the rule would have committed
/// 193 words of `/usr/share/dict/words` as text that is no syllable (`Amon`, `Aiona`); at the end of the token, 3
/// (`bortz`, `hertz`, `wootz` give `bot`, `het`, `uot`).
@Suite("Rule L4a: a tone removal at commit (ENG-R411, REG-39)")
struct ToneRemovalCommitTests {
    static let vni = EngineConfiguration(inputMethod: .vni, typoCorrection: false)

    /// The 13.9 fixtures with English words whose `z` removes a mark that the letters before it made: at the end
    /// (`quartz`, `hertz`) or before more letters (`booze`, `breeze`).
    static let englishWithZ: Resources = {
        var resources = SpecFixtures.commitResources()
        resources.english = WordSet(SpecFixtures.englishLexicon + ["booze", "breeze", "quartz", "hertz"])
        return resources
    }()

    @Test(
        "The text the removal left is kept, whether or not it is a syllable",
        arguments: [
            ("dduwowngfzz ", "duong "), ("vieejtz ", "viêt "), ("vieejtzz ", "viet "), ("daauszz ", "dau "),
            ("testz ", "tet "), ("DDUWOWNGFZZ ", "DUONG "), ("Vieejtz,", "Viêt,"), ("dduwowngfzz.", "duong."),
        ])
    func keepsTheTextShownInTelex(_ keys: String, _ expected: String) throws {
        let driver = try Committing.driver(keys)
        #expect(driver.field.string == expected)
        #expect(driver.outputs.last?.decision == .kept(.toneRemoval))
    }

    @Test(
        "VNI 0 follows the same rule",
        arguments: [("d9u7o7ng200 ", "duong "), ("vie65t0 ", "viêt "), ("vie65t00 ", "viet ")])
    func keepsTheTextShownInVNI(_ keys: String, _ expected: String) throws {
        let driver = try Committing.driver(keys, Self.vni)
        #expect(driver.field.string == expected)
        #expect(driver.outputs.last?.decision == .kept(.toneRemoval))
    }

    @Test("English raw keys are restored")
    func englishRawKeysAreRestored() throws {
        for word in ["quartz", "hertz", "QUARTZ"] {
            let driver = try Committing.driver(word + " ", resources: Self.englishWithZ)
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision == .restored(.toneRemoval), "\(word)")
        }
        // A removal before more letters: the rules after L4a restore them as before (`boe` and `brê` are no syllables
        // of Tier A, and the keys are English).
        for word in ["booze", "breeze"] {
            let driver = try Committing.driver(word + " ", resources: Self.englishWithZ)
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision?.rule != .toneRemoval, "\(word)")
        }
        // In an English run and in the code context alike: L4a reads only the raw keys.
        #expect(try Committing.text("and quartz ", resources: Self.englishWithZ) == "and quartz ")
        #expect(
            try Committing.text(
                "quartz ", EngineConfiguration(appContext: .code, typoCorrection: false), resources: Self.englishWithZ)
                == "quartz ")
    }

    @Test("ENG-R802: with auto restore off L4a restores nothing and still names itself")
    func autoRestoreOff() throws {
        let off = EngineConfiguration(autoRestore: false, typoCorrection: false)
        let driver = try Committing.driver("quartz ", off, resources: Self.englishWithZ)
        #expect(driver.field.string == "quat " && driver.outputs.last?.decision == .kept(.toneRemoval))
        #expect(try Committing.decision("dduwowngfzz ", off) == .kept(.toneRemoval))
    }

    @Test("Earlier rules still decide first: the user's choice, the user lists, abbreviations, an escape")
    func earlierRulesWin() throws {
        // L1: the restore toggle brings the keys back and the commit keeps them.
        #expect(try Committing.text("dduwowngfzz⎋ ") == "dduwowngfzz ")
        #expect(try Committing.decision("dduwowngfzz⎋ ") == .restored(.userChoice))
        // L2: the keep-as-typed list.
        let listed = SpecFixtures.commitResources(userKeepRaw: ["dduwowngfzz"])
        #expect(try Committing.text("dduwowngfzz ", resources: listed) == "dduwowngfzz ")
        // L3: no vowel letter (`ddz` removes the stroke).
        #expect(try Committing.decision("ddz ") == .kept(.abbreviation))
        // L4: a token with an escape and a removal is decided as an escape.
        #expect(try Committing.decision("aazaa ") == .kept(.escape))
    }

    @Test("A key with nothing to remove is a letter: no removal, the rules after L4a decide")
    func noRemovalNoRule() throws {
        #expect(try Committing.decision("quz ") == .kept(.unchanged))
        #expect(try Committing.decision("za ") == .kept(.unchanged))
        // `daauszzz`: the third `z` finds nothing and is a letter, so the token does not end with a removal; `dauz` is no
        // syllable and L5 restores the keys.
        #expect(try Committing.text("daauszzz ") == "daauszzz ")
        #expect(try Committing.decision("daauszzz ") == .restored(.invalid))
    }

    @Test(
        "A removal that more letters follow is a word typed through: the rules after L4a decide",
        arguments: [("Amazon ", "Amazon "), ("Arizona ", "Arizona "), ("vieejtzs ", "viết ")])
    func removalBeforeMoreLetters(_ keys: String, _ expected: String) throws {
        // `Amazon` shows `Amon` (the `z` removed the circumflex of `âm`), `Arizona` shows `Aiona`: no syllables, L5.
        let driver = try Committing.driver(keys)
        #expect(driver.field.string == expected)
        #expect(driver.outputs.last?.decision?.rule != .toneRemoval)
    }

    @Test("Backspace re-replays the keys: a removal deleted with its letters no longer counts")
    func backspaceRecomputesTheFlag() throws {
        // `aaz` + Backspace leaves an empty token; `b`, `a`, `n` then type `ban` with no removal.
        #expect(try Committing.decision("aaz⌫ban ") == .kept(.unchanged))
        // A removal that stays decides: `dduwowngfzz` + Backspace shows `duon`.
        let driver = try Committing.driver("dduwowngfzz⌫ ")
        #expect(driver.field.string == "duon " && driver.outputs.last?.decision == .kept(.toneRemoval))
    }

    @Test("Known cost (ENG-R411): a word outside the lexicon that ends with a removal keeps what it shows")
    func knownCostOfTheLastKey() throws {
        // `hertz` is not in the 13.9 lexicon: the `z` removes the tone of `hẻt`, so the commit keeps `het`. The escape
        // by doubling gives the word (4.7, rule L4), and a further `z` is a letter, so the rules after L4a decide.
        #expect(try Committing.text("hertz ") == "het ")
        #expect(try Committing.text("herrtz ") == "hertz ")
        #expect(try Committing.text("hertzz ") == "hertzz ")
    }

    @Test("The kept token is evidence like any kept token (ENG-R823)")
    func languageOfTheKeptToken() throws {
        // `viêt` shows a Vietnamese-only letter, so the run is not English and `car` keeps `cả` (L11 vi row).
        #expect(try Committing.text("vieejtz car ") == "viêt cả ")
    }
}
