// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Rule L4 of 8.1 as amended by the product owner on 17/11/2026 (ENG-R801, REG-37), with the 13.9 fixtures plus a
/// few English words. `C` is the display with the escape, `R` the raw keys; a doubling is an escape key right after
/// the key whose effect it removes:
///
/// | `C` English | `R` English | Result |
/// |---|---|---|
/// | yes | yes | keep when the escape was a needed doubling (the keys of `C` alone commit something else) and the context is not English; else restore |
/// | yes | no | keep (`tarr` -> `tar`, `ddid` -> `did`) |
/// | no | yes | restore (`password`, `www`) |
/// | no | no | keep when every escape was a doubling and `C` holds one vowel group at most or ends with the escape; else restore |
@Suite("Rule L4: the escape at commit (ENG-R801, REG-37)")
struct EscapeCommitTests {
    /// The 13.9 fixtures with `off`, `of`, `dessert`, `desert`, `costs` and `cots` added to the English lexicon. `of`
    /// and `cots` have no ambiguity row, so their keys alone commit `ò` and `cót` (L11 default); `desert` typed alone
    /// shows `dểt`, an invalid syllable (3.11), so L5 restores its keys.
    static let resources: Resources = {
        var resources = SpecFixtures.commitResources()
        resources.english = WordSet(SpecFixtures.englishLexicon + ["off", "of", "dessert", "desert", "costs", "cots"])
        return resources
    }()

    static func driver(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws
        -> EngineDriver
    {
        try Committing.driver(keys, configuration, resources: resources)
    }

    static func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws -> String {
        try driver(keys, configuration).field.string
    }

    static func decision(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws
        -> CommitDecision?
    {
        try driver(keys, configuration).outputs.last?.decision
    }

    // MARK: - C and R both English

    @Test("Both English, the escape was not needed: the keys of C alone already commit C, so R is restored")
    func escapeNotNeededRestoresTheKeys() throws {
        // `desert` typed alone shows `dểt` and L5 restores `desert`: the doubled `s` of `dessert` was a letter.
        #expect(try Self.text("desert ") == "desert ")
        #expect(try Self.text("dessert ") == "dessert ")
        #expect(try Self.decision("dessert ") == .restored(.escape))
        // Whatever the context: after a Vietnamese word too.
        #expect(try Self.text("vieejt dessert ") == "việt dessert ")
    }

    @Test("Both English, the escape was needed: kept alone and after Vietnamese, restored in an English run")
    func escapeNeededFollowsTheRun() throws {
        // `of` typed alone commits `ò` (L11 default): doubling is the only way to get `of`, a deliberate escape.
        #expect(try Self.text("of ") == "ò ")
        #expect(try Self.text("off ") == "of ")
        #expect(try Self.decision("off ") == .kept(.escape))
        #expect(try Self.text("vieejt off ") == "việt of ")
        // ENG-R823: an English token and no Vietnamese token among the previous three.
        #expect(try Self.text("and off ") == "and off ")
        #expect(try Self.decision("and off ") == .restored(.escape))
        #expect(try Self.text("and vieejt off ") == "and việt of ")
    }

    @Test("Both English, the escape is no doubling: the keys are restored (costs, not cots)")
    func escapeAcrossKeysRestoresTheKeys() throws {
        // `costs` shows `cót`, and the second `s`, after `t`, escapes the tone (ENG-R410): `cots`, which typed alone
        // commits `cót`. The tone letter came back in a plural, not as a doubling.
        #expect(try Self.text("cots ") == "cót ")
        #expect(try Self.text("costs ") == "costs ")
        #expect(try Self.decision("costs ") == .restored(.escape))
        #expect(try Self.text("vieejt costs ") == "việt costs ")
    }

    @Test("Both English: the keys of C are decided with the same resources, user lists included")
    func escapeNeededReadsTheSameResources() throws {
        var resources = Self.resources
        resources.userKeepRaw = WordSet(["of"])
        // With `of` on the keep-as-typed list its keys alone commit `of` (L2), so the escape was not needed.
        #expect(try Committing.text("of ", resources: resources) == "of ")
        #expect(try Committing.text("off ", resources: resources) == "off ")
        #expect(try Committing.decision("off ", resources: resources) == .restored(.escape))
    }

    @Test("Both English: the learned memory does not decide whether the escape was needed (ENG-R877)")
    func escapeNeededLeavesTheMemoryOut() throws {
        var resources = Self.resources
        resources.ambiguity["of"] = .vietnamese
        resources.collisionMemory = CollisionMemorySnapshot([.init(word: "of", context: nil, choice: .english)])
        // The memory decides the collision word itself (L9c) ...
        #expect(try Committing.text("of ", resources: resources) == "of ")
        #expect(try Committing.decision("of ", resources: resources) == .restored(.learned))
        // ... but the doubling stays the deliberate escape: the rules alone give `ò` for `of`.
        #expect(try Committing.text("off ", resources: resources) == "of ")
        #expect(try Committing.decision("off ", resources: resources) == .kept(.escape))
    }

    @Test("ENG-R802: with auto restore off L4 keeps C and still names itself")
    func autoRestoreOffKeepsTheEscapedForm() throws {
        let off = EngineConfiguration(autoRestore: false)
        for (keys, text) in [("dessert ", "desert "), ("and off ", "and of "), ("leecher ", "lecher ")] {
            let driver = try Self.driver(keys, off)
            #expect(driver.field.string == text, "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(.escape), "\(keys)")
        }
    }

    // MARK: - Only one of them English

    @Test("C English, R not English: kept whatever the context (tarr, ddid, ass with the 13.9 lexicon)")
    func escapedFormEnglishKeysNot() throws {
        for (keys, text) in [
            ("tarr ", "tar "), ("and tarr ", "and tar "), ("ddid ", "did "), ("ass ", "as "), ("and ass ", "and as "),
        ] {
            let driver = try Self.driver(keys)
            #expect(driver.field.string == text, "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(.escape), "\(keys)")
        }
        #expect(try Self.text("tarr ", EngineConfiguration(appContext: .code)) == "tar ")
    }

    @Test("R English, C not English: restored (password, traffic, www of ENG-T12)")
    func keysEnglishEscapedFormNot() throws {
        for word in ["password", "traffic", "boss", "coffee", "less", "tomorrow", "www"] {
            let driver = try Self.driver(word + " ")
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision == .restored(.escape), "\(word)")
        }
    }

    // MARK: - Neither English

    @Test("Neither English, C holds two vowel groups and the token went on after the escape: restored")
    func severalVowelGroupsAfterTheEscapeRestore() throws {
        // `leecher` shows `lêch`, the third `e` escapes the circumflex (ENG-R412, ENG-R440) and `r` follows:
        // `lecher` cannot be one Vietnamese syllable, so the keys were a word typed through.
        for word in ["leecher", "cheeseburger", "coffeehouse", "cookout", "beefsteak", "deepener", "current"] {
            let driver = try Self.driver(word + " ")
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision == .restored(.escape), "\(word)")
        }
        #expect(try Self.text("Leecher, ") == "Leecher, ")
    }

    @Test("Neither English, an escape that is no doubling: restored even with one vowel group or at the end")
    func escapeAcrossKeysIsNotDeliberate() throws {
        // `beefer` shows `bề`, the `e` after `f` escapes the circumflex: `bèer`, one vowel group. `pajama` shows
        // `pậm` (a circumflex key after the coda, ENG-R431) and its last `a` escapes it: `pạma`, ending with the
        // escape. `arar` shows `ẩ` and its second `r` escapes the tone: `âr`. None is a doubling.
        for word in ["beefer", "pajama", "arar", "wsaw"] {
            let driver = try Self.driver(word + " ")
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision == .restored(.escape), "\(word)")
        }
    }

    @Test("Known cost: a tone key between the circumflex key and its escape is no doubling (theesee, not thesee)")
    func toneKeyBetweenBreaksTheDoubling() throws {
        // ENG-R804 known costs: the chat elongation of `thế` typed with the tone before the extra `e` restores the
        // keys, while the tone typed first keeps the escaped form; neither is the intended `thếee`. Counting a key
        // that adds no letter as part of the doubling would keep `théee`, but then `referent`, `samsara` and
        // `menses` (59 words of /usr/share/dict/words, none in the lexicon) would commit `rẻent`, `sảma`, `mêns`.
        for word in ["theesee", "theeseee", "coosooo", "caasaa", "referent", "samsara", "menses"] {
            let driver = try Self.driver(word + " ")
            #expect(driver.field.string == word + " ", "\(word)")
            #expect(driver.outputs.last?.decision == .restored(.escape), "\(word)")
        }
        for (keys, text) in [("thesee ", "thée "), ("cosooo ", "cóoo "), ("casaa ", "cáa ")] {
            let driver = try Self.driver(keys)
            #expect(driver.field.string == text, "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(.escape), "\(keys)")
        }
    }

    @Test("Neither English, one vowel group at most: the escape is deliberate and C is kept")
    func oneVowelGroupKeepsTheEscapedForm() throws {
        for (keys, text) in [
            ("nhaamff ", "nhâmf "), ("boooong ", "booong "), ("sooocs ", "soóc "), ("ddd ", "dd "), ("uww ", "uw "),
            ("aaa ", "aa "), ("ww ", "w "), ("Ea Karr ", "Ea Kar "), ("Cuw M'garr ", "Cư M'gar "),
        ] {
            let driver = try Self.driver(keys)
            #expect(driver.field.string == text, "\(keys)")
            #expect(driver.outputs.last?.decision == .kept(.escape), "\(keys)")
        }
        let vni = EngineConfiguration(inputMethod: .vni)
        #expect(try Self.text("a11 ", vni) == "a1 ")
        #expect(try Self.text("d99 ", vni) == "d9 ")
    }

    @Test("Neither English, the escape key ended the token: the user saw C and committed it (Krông Ana)")
    func escapeAsTheLastKeyKeepsTheEscapedForm() throws {
        // PN203T: `Anaa` shows `Ân` (a circumflex key after the coda, ENG-R431), then `a` escapes: `Ana`.
        let driver = try Self.driver("Kroong Anaa ")
        #expect(driver.field.string == "Krông Ana ")
        #expect(driver.outputs.last?.decision == .kept(.escape))
        // One more letter after the escape: the token went on, and `Anab` is restored.
        #expect(try Self.text("Anaab ") == "Anaab ")
    }

    // MARK: - The facts L4 reads

    @Test("CommittedTextFacts counts the vowel groups of C: maximal runs of vowel letters")
    func vowelGroups() {
        for (text, groups) in [
            ("", 0), ("dd", 0), ("w", 0), ("uw", 1), ("booong", 1), ("nhâmf", 1), ("soóc", 1), ("quê", 1),
            ("giếng", 1), ("Ana", 2), ("lecher", 2), ("chéeburger", 3), ("a1", 1), ("a1a", 2), ("ƯỚkpace", 3),
        ] {
            #expect(CommittedTextFacts(text).vowelGroups == groups, "\(text)")
        }
    }

    @Test("Composition knows whether its last key was an escape")
    func endsWithEscape() {
        let telex = ComposerRules(EngineConfiguration())
        func ends(_ keys: String, _ rules: ComposerRules = telex) -> Bool {
            Composition(replaying: Array(keys.utf8), rules: rules).endsWithEscape
        }
        // The escape letter is a letter (`Karr`, `Anaa`, `aaa`) or starts literal mode (`ass`, `nhaamff`, `ww`).
        for keys in ["Karr", "Anaa", "aaa", "ass", "nhaamff", "ww", "off", "ddd"] { #expect(ends(keys), "\(keys)") }
        for keys in ["", "a", "aa", "www", "boooong", "leecher", "assa", "Anaab", "vieejt"] {
            #expect(!ends(keys), "\(keys)")
        }
        let vni = ComposerRules(EngineConfiguration(inputMethod: .vni))
        #expect(ends("a11", vni) && ends("d99", vni) && !ends("a1", vni) && !ends("a111", vni))
    }

    @Test("Composition knows whether an escape key came after other keys instead of doubling its key")
    func escapedAcrossKeys() {
        let telex = ComposerRules(EngineConfiguration())
        func across(_ keys: String, _ rules: ComposerRules = telex) -> Bool {
            Composition(replaying: Array(keys.utf8), rules: rules).escapedAcrossKeys
        }
        // Doublings of every kind: tone, circumflex, horn and breve, standalone `w`, stroke; a tone set twice
        // (`afss`: the escape undoes `f` and `s`, the last of them right before it).
        for keys in [
            "off", "ass", "afss", "Anaa", "boooong", "aaa", "aww", "uww", "ww", "ddd", "nhaamff", "vieejt", "thesee",
        ] {
            #expect(!across(keys), "\(keys)")
        }
        // A key between the undone key and the escape breaks the doubling, even one that adds no letter (the tone
        // key `s` of `theesee`, ENG-R804 known costs).
        for keys in ["costs", "leecher", "pajama", "beefer", "ddid", "wsaw", "cookout", "theesee"] {
            #expect(across(keys), "\(keys)")
        }
        let vni = ComposerRules(EngineConfiguration(inputMethod: .vni))
        #expect(!across("a11", vni) && !across("d99", vni) && across("a1n1", vni))
    }
}
