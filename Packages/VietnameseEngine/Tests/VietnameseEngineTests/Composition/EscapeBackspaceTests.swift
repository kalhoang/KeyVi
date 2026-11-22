// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R711 as amended by the product owner on 15/11/2026: Backspace on a letter that an escape key
/// produced removes the escaping key and the earlier keys whose effect it undid, so the field loses
/// exactly its last character (ENG-R714, ENG-T38) and the stickiness of that kind ends (ENG-R441). The
/// first version brought the escaped effect back (`boss` + Backspace gave `bó`).
@Suite("Backspace on an escape letter (ENG-R711)")
struct EscapeBackspaceTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let keys: String
        let expected: String
        var method: CorpusMethod = .telex
        var bracketKeys = false

        var configuration: EngineConfiguration {
            switch method {
            case .telex:
                return EngineConfiguration(
                    inputMethod: .telex(TelexOptions(bracketKeys: bracketKeys)), typoCorrection: false)
            case .vni: return EngineConfiguration(inputMethod: .vni, typoCorrection: false)
            }
        }

        var testDescription: String { "\(method) \(keys) -> \(expected.debugDescription)" }
    }

    static let rows: [Row] = [
        // The product owner's examples (15/11/2026).
        Row(keys: "boss⌫", expected: "bo"),
        Row(keys: "nhaamff⌫", expected: "nhâm"),
        Row(keys: "ass⌫", expected: "a"),
        Row(keys: "verr⌫", expected: "ve"),
        Row(keys: "Saff⌫", expected: "Sa"),
        Row(keys: "Quyeenff⌫", expected: "Quyên"),
        Row(keys: "teee⌫", expected: "te"),
        Row(keys: "cass⌫", expected: "ca"),
        // `ww` shows `w`; the escape removed the standalone `ư`, so both keys go.
        Row(keys: "ww⌫", expected: ""),
        Row(keys: "WW⌫", expected: ""),
        // The `S` put its tone on the `Ư` that the escape removed: it goes too instead of coming back as
        // a letter (ENG-R432 note), so the field still loses exactly its last character.
        Row(keys: "WSw⌫", expected: ""),
        // A tone key typed before the vowel that the escape removed, with another vowel after it: the
        // tone shows on that vowel (`wsaw` shows `áw`), so the replay applies the tone key once the vowel
        // is back and the field keeps `á` (ENG-R432 note, ENG-T38).
        Row(keys: "wsaw⌫", expected: "á"),
        Row(keys: "WSaw⌫", expected: "á"),
        Row(keys: "wfaw⌫", expected: "à"),
        Row(keys: "wsoww⌫", expected: "ó"),
        Row(keys: "wsfaw⌫", expected: "à"),
        Row(keys: "wfsaw⌫", expected: "á"),
        // The whole chain of tone keys waits for the vowel, the removal included (ENG-R411).
        Row(keys: "wszaw⌫", expected: "a"),
        Row(keys: "wszfaw⌫", expected: "à"),
        Row(keys: "]sa]⌫", expected: "á", bracketKeys: true),
        // A mark removal never waits: with its letters gone it goes (`uowzw` shows `uow`).
        Row(keys: "uowzw⌫", expected: "ư"),
        // Every kind: circumflex (an escape letter that stays a letter, `oo`), stroke, Telex `w`, VNI.
        Row(keys: "booo⌫", expected: "bo"),
        Row(keys: "aaa⌫", expected: "a"),
        Row(keys: "ddd⌫", expected: "d"),
        Row(keys: "dangdd⌫", expected: "dang"),
        Row(keys: "aww⌫", expected: "a"),
        Row(keys: "tuoww⌫", expected: "tuo"),
        Row(keys: "nhesee⌫", expected: "nhé"),
        Row(keys: "a11⌫", expected: "a", method: .vni),
        Row(keys: "a66⌫", expected: "a", method: .vni),
        Row(keys: "d99⌫", expected: "d", method: .vni),
        Row(keys: "a88⌫", expected: "a", method: .vni),
        Row(keys: "tuo77⌫", expected: "tuo", method: .vni),
        Row(keys: "m[[⌫", expected: "m", bracketKeys: true),
        // A circumflex escape on the `o` of `ươ` also undoes the horn keys of the `u` whose horn the
        // circumflex removed (ENG-R533), so the `u` stays plain.
        Row(keys: "uwooo⌫", expected: "uo"),
        Row(keys: "uowoo⌫", expected: "uo"),
        // Fallback: an `ư` whose horn comes from its own key (standalone `w`, bracket key) cannot be shown
        // as `u` by its key, so that key is kept as a `u` key and the field still loses one character.
        Row(keys: "wooo⌫", expected: "uo"),
        Row(keys: "WOOO⌫", expected: "UO"),
        Row(keys: "]w⌫", expected: "u", bracketKeys: true),
        // The same for the `ơ` of a bracket key, unmarked by a `w` escape or a circumflex escape.
        Row(keys: "[w⌫", expected: "o", bracketKeys: true),
        Row(keys: "[sw⌫", expected: "ó", bracketKeys: true),
        Row(keys: "[oo⌫", expected: "o", bracketKeys: true),
        // Bracket doubling removes the bracket letters and their mark keys, except a mark key that still
        // marks a letter that stays: the `w` of `]ow]` gave the `ơ` its horn.
        Row(keys: "]ow]⌫", expected: "ơ", bracketKeys: true),
        Row(keys: "u[w[⌫", expected: "ư", bracketKeys: true),
        // Last resort, the token retyped from the letters shown: the remaining keys no longer allow the
        // transform in the order typed (the stroke of `dwndw` applied while the `ư` stood; `ơu` takes no
        // tone key; a bracket letter in an all-caps word, ENG-R906).
        Row(keys: "dwndw⌫", expected: "đn"),
        Row(keys: "]ous]⌫", expected: "óu", bracketKeys: true),
        Row(keys: "][us]⌫", expected: "ớu", bracketKeys: true),
        Row(keys: "S][U]⌫", expected: "SƠU", bracketKeys: true),
        // The vowel that took the tone went with the escape and no letter shown can take it: the token
        // is retyped without the tone key (ENG-R432, ENG-R710), not left in literal mode.
        Row(keys: "dwnsdw⌫", expected: "đn"),
        Row(keys: "dwsndw⌫", expected: "đn"),
        Row(keys: "dwngsdw⌫", expected: "đng"),
        Row(keys: "DWNSDW⌫", expected: "ĐN"),
        Row(keys: "d]nsd]⌫", expected: "đn", bracketKeys: true),
        Row(keys: "d[nsd[⌫", expected: "đn", bracketKeys: true),
    ]

    @Test(arguments: rows)
    func escapeLetterGoesWithTheKeysItUndid(_ row: Row) throws {
        var driver = EngineDriver(configuration: row.configuration)
        try driver.send(KeyNotation.events(row.keys))
        #expect(driver.field.string == row.expected, "\(row.keys)")
        #expect(driver.state.activeDisplay == row.expected, "\(row.keys)")
        // ENG-R712: the display lost exactly its last character, so the app deletes it itself.
        #expect(driver.outputs.last?.action == .passThrough, "\(row.keys)")
    }

    /// The keys typed after the Backspace compose as if the escape had never been typed: the stickiness
    /// of the kind ended (ENG-R441) and the effect can be applied again (REG-24).
    @Test(arguments: [
        ("boss⌫s", "bó"), ("boss⌫ss", "bos"), ("nhaamff⌫f", "nhầm"), ("cass⌫o", "cao"), ("teee⌫e", "tê"),
        ("teee⌫epj", "tệp"), ("ass⌫s", "á"), ("ww⌫w", "ư"), ("booo⌫o", "bô"), ("dangdd⌫d", "đang"),
    ])
    func keysAfterTheBackspaceComposeAgain(keys: String, expected: String) throws {
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.send(KeyNotation.events(keys))
        #expect(driver.field.string == expected, "\(keys)")
    }

    /// The raw keys lose the escaping key and the keys it undid, so the restore toggle gives what is left.
    @Test func rawKeysLoseTheEscapeAndWhatItUndid() throws {
        for (keys, raw) in [("boss⌫", "bo"), ("nhaamff⌫", "nhaam"), ("teee⌫", "te"), ("ww⌫", ""), ("WSw⌫", "")] {
            var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
            try driver.send(KeyNotation.events(keys))
            #expect(driver.state.activeRawKeys == raw, "\(keys)")
        }
    }

    /// The replay keeps the keys as typed where it can, so the restore toggle shows them; the retyping
    /// of fallback 2 would give the same text from other keys. A waiting tone key moves after the letter
    /// that takes it (`wsaw`, `wsfaw`, `wszaw`, ENG-R432); a bracket key's escape keeps the mark key that
    /// still marks a letter (`]sow]`, not `ows`); a bracket `ơ` shown plain is kept as an `o` key in its
    /// place (`[snw`, not `ons`; `[szw`, not `o`; fallback 1).
    @Test(arguments: [
        ("wsaw⌫", "as", false), ("wsfaw⌫", "asf", false), ("wszaw⌫", "asz", false),
        ("]sow]⌫", "osw", true), ("[snw⌫", "osn", true), ("[szw⌫", "osz", true), ("]s[w⌫", "uso", true),
    ])
    func rawKeysKeepTheTypedOrder(keys: String, raw: String, bracketKeys: Bool) throws {
        let configuration = EngineConfiguration(
            inputMethod: .telex(TelexOptions(bracketKeys: bracketKeys)), typoCorrection: false)
        var driver = EngineDriver(configuration: configuration)
        try driver.send(KeyNotation.events(keys))
        #expect(driver.state.activeRawKeys == raw, "\(keys)")
    }

    /// A retyped token (fallback 2) keeps deleting one character per press, and its raw keys are the
    /// keys that type the letters shown, without a tone key that no letter shown takes.
    @Test func retypedTokenWithoutItsToneKey() throws {
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.send(KeyNotation.events("dwngsdw"))
        #expect(driver.field.string == "đngw")
        try driver.send(.backspace)
        #expect(driver.field.string == "đng" && driver.state.activeRawKeys == "ddng")
        try driver.send(.backspace)
        #expect(driver.field.string == "đn" && driver.outputs.last?.action == .passThrough)
        try driver.send(.backspace)
        try driver.send(.backspace)
        #expect(driver.field.string == "" && driver.outputs.last?.action == .passThrough)
    }

    /// An escape letter that stays a letter (`oo`, `soóc`) is deleted like any letter, its tone staying on
    /// the letter it is shown on: `sooocs` shows `soóc`, Backspace gives `sóo` (the tone moves, ENG-R714
    /// (a)), then `só`.
    @Test func escapeLetterThatStaysALetter() throws {
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.send(KeyNotation.events("sooocs"))
        #expect(driver.field.string == "soóc")
        try driver.send(.backspace)
        #expect(driver.field.string == "sóo")
        try driver.send(.backspace)
        #expect(driver.field.string == "só" && driver.outputs.last?.action == .passThrough)
        #expect(try Committing.text("booos⌫", resources: .empty) == "bó")
    }

    /// The same rule inside a word re-opened from history (ENG-R1002, ENG-R1003): with no resources L4
    /// keeps `nhâmf`, and Backspace on the re-opened escape `f` takes the tone key with it.
    @Test func reopenedWordFollowsTheSameRule() throws {
        let driver = try Committing.driver("nhaamff ⌫⌫", resources: .empty)
        #expect(driver.field.string == "nhâm")
    }
}
