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
            case .telex: return EngineConfiguration(inputMethod: .telex(TelexOptions(bracketKeys: bracketKeys)))
            case .vni: return EngineConfiguration(inputMethod: .vni)
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
        var driver = EngineDriver(configuration: EngineConfiguration())
        try driver.send(KeyNotation.events(keys))
        #expect(driver.field.string == expected, "\(keys)")
    }

    /// The raw keys lose the escaping key and the keys it undid, so the restore toggle gives what is left.
    @Test func rawKeysLoseTheEscapeAndWhatItUndid() throws {
        for (keys, raw) in [("boss⌫", "bo"), ("nhaamff⌫", "nhaam"), ("teee⌫", "te"), ("ww⌫", ""), ("WSw⌫", "")] {
            var driver = EngineDriver(configuration: EngineConfiguration())
            try driver.send(KeyNotation.events(keys))
            #expect(driver.state.activeRawKeys == raw, "\(keys)")
        }
    }

    /// An escape letter that stays a letter (`oo`, `soóc`) is deleted like any letter, its tone staying on
    /// the letter it is shown on: `sooocs` shows `soóc`, Backspace gives `sóo` (the tone moves, ENG-R714
    /// (a)), then `só`.
    @Test func escapeLetterThatStaysALetter() throws {
        var driver = EngineDriver(configuration: EngineConfiguration())
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
