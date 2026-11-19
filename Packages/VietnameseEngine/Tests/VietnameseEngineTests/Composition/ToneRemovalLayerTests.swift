// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R411 as amended by the product owner on 15/11/2026: Telex `z` and VNI `0` remove one layer per
/// press. With a tone the key removes the tone; otherwise, when a letter carries a vowel mark
/// (circumflex, horn, breve) or the token has `đ`, the key removes all of them at once (`đ` becomes
/// `d`); otherwise the key is a letter (Telex) or a literal digit (VNI) as before. Reported by the
/// product owner: `daauszz` gave `dâuz` where `dau` was expected (REG-34).
@Suite("Tone removal by layers (ENG-R411)")
struct ToneRemovalLayerTests {
    private static let telex = EngineConfiguration(typoCorrection: false)
    private static let vni = EngineConfiguration(inputMethod: .vni, typoCorrection: false)

    private static func display(_ keys: String, _ configuration: EngineConfiguration = telex) throws -> String {
        var driver = EngineDriver(configuration: configuration)
        try driver.send(KeyNotation.events(keys))
        #expect(driver.field.string == driver.state.activeDisplay, "\(keys): field and view agree (ENG-T31)")
        return driver.state.activeDisplay
    }

    @Test(arguments: [
        // The product owner's examples.
        ("daausz", "dâu"), ("daauszz", "dau"), ("daauszzz", "dauz"), ("dduwowngfzz", "duong"), ("aaz", "a"),
        // One press per layer: tone, then every mark of the token at once, then a letter.
        ("asz", "a"), ("aszz", "az"), ("dduwowcjz", "đươc"), ("dduwowcjzz", "duoc"), ("tuwz", "tu"),
        ("awz", "a"), ("ddz", "d"), ("ddaz", "da"), ("DDAAUSZZ", "DAU"), ("Ddaauszz", "Dau"),
        // A standalone `ư` loses its horn like any other letter (ENG-R103).
        ("wz", "u"),
        // Unchanged: no tone and no mark, so `z` is a letter (REG-01, REG-25, the Tier B `dz` onset).
        ("quz", "quz"), ("QUZ", "QUZ"), ("za", "za"), ("zas", "zá"), ("dz", "dz"), ("dzoo", "dzô"),
        ("vieejtz", "viêt"),
    ])
    func telexLayers(keys: String, expected: String) throws {
        #expect(try Self.display(keys) == expected, "\(keys)")
    }

    @Test(arguments: [
        ("a610", "â"), ("a6100", "a"), ("a61000", "a0"), ("d90", "d"), ("a60", "a"), ("duo7c50", "dươc"),
        ("d9uo7c50", "đươc"), ("d9uo7c500", "duoc"), ("qu0", "qu0"), ("a10", "a"), ("a100", "a0"),
    ])
    func vniLayers(keys: String, expected: String) throws {
        #expect(try Self.display(keys, Self.vni) == expected, "\(keys)")
    }

    /// After a removal every key keeps its role, as after a tone removal (`aszs` gives `á`): a tone key
    /// sets a tone, a modifier or stroke key marks again and a second press of it escapes, and a further
    /// tone-removal key starts again from the top layer.
    @Test(arguments: [
        ("aszs", "á"), ("aaza", "â"), ("aazaa", "aa"), ("daauszza", "dâu"), ("daauszzaa", "daua"),
        ("daauszzs", "dáu"), ("ddzd", "đ"), ("ddzdd", "dd"), ("tuwzw", "tư"), ("aazaz", "a"), ("aazazz", "az"),
    ])
    func keysAfterARemovalKeepTheirRoles(keys: String, expected: String) throws {
        #expect(try Self.display(keys) == expected, "\(keys)")
    }

    /// ENG-T38: Backspace after a removal still takes exactly the last character. A removal key goes with
    /// the deleted letter once nothing is left for it to remove; it never comes back as a letter.
    @Test(arguments: [
        ("daauszz⌫", "da"), ("aaz⌫", ""), ("ddaaz⌫", "d"), ("dduwowngfzz⌫", "duon"), ("tooz⌫", "t"),
        ("uowzw⌫", "ư"), ("ddaazaz⌫", "d"), ("woz⌫", "u"), ("wzw⌫", ""), ("daauszzs⌫", "dá"),
        ("daauszzss⌫", "dau"),
        // A removal clears every mark, so the horn the `ư` shows after it comes from the later `w` alone,
        // which stays for it (ENG-R710): the standalone `w` no longer gives the mark.
        ("wzow⌫", "ư"), ("wozw⌫", "ư"), ("Wzow⌫", "Ư"),
    ])
    func backspaceAfterARemovalOnlyDeletes(keys: String, expected: String) throws {
        var driver = EngineDriver(configuration: Self.telex)
        try driver.send(KeyNotation.events(keys))
        #expect(driver.field.string == expected, "\(keys)")
        #expect(driver.outputs.last?.action == .passThrough, "\(keys): ENG-R712")
    }

    @Test func vniBackspaceAfterARemovalOnlyDeletes() throws {
        var driver = EngineDriver(configuration: Self.vni)
        try driver.send(KeyNotation.events("da6u100⌫"))
        #expect(driver.field.string == "da")
        // The `7` after the removal alone gives the horn of the `ư` (ENG-R710, ENG-R411).
        var second = EngineDriver(configuration: Self.vni)
        try second.send(KeyNotation.events("u70o7⌫"))
        #expect(second.field.string == "ư")
    }

    /// The commit keeps the unmarked word (rule L4a, REG-39: the last key removed the marks); the raw keys keep every
    /// key typed (ENG-R602), so the restore toggle gives them back.
    @Test func commitKeepsTheUnmarkedWord() throws {
        let driver = try Committing.driver("daauszz ")
        #expect(driver.field.string == "dau ")
        #expect(try Committing.text("dduwowngfzz ") == "duong ")
        #expect(try Committing.text("daauszz⎋") == "daauszz")
    }

    /// English words whose display changes mid-word because `z` now removes a circumflex still commit as
    /// typed when they are English (L5 or L6), and words without a mark before the `z` are untouched.
    @Test func englishWordsWithZStillCommitAsTyped() throws {
        let words = ["booze", "breeze", "boozer", "fizz", "jazz", "pizza", "ozone", "dozen", "squeeze", "oozes"]
        let resources = Resources(
            english: WordSet(words), techAlways: WordSet([]), techCodeOnly: WordSet([]),
            attestedSyllables: WordSet([]), ambiguity: [:], userKeepRaw: WordSet([]),
            userKeepVietnamese: WordSet([]))
        for word in words {
            #expect(try Committing.text(word + " ", resources: resources) == word + " ", "\(word)")
        }
        #expect(try Self.display("booze") == "boe")
        #expect(try Self.display("breeze") == "brê")
        #expect(try Self.display("pizza") == "pizza")
    }
}
