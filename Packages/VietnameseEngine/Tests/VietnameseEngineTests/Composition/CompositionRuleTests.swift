// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Helpers shared by the composition rule tests.
enum Typing {
    static let telex = EngineConfiguration()
    static let modern = EngineConfiguration(toneStyle: .modern)
    static let vni = EngineConfiguration(inputMethod: .vni)

    /// Types `keys` (`⌫` is Backspace) through the simulated field and returns the driver.
    static func driver(_ keys: String, _ configuration: EngineConfiguration = telex) throws -> EngineDriver {
        var driver = EngineDriver(configuration: configuration)
        try driver.type(keys)
        return driver
    }

    /// The active display after typing `keys`.
    static func display(_ keys: String, _ configuration: EngineConfiguration = telex) throws -> String {
        try driver(keys, configuration).state.activeDisplay
    }
}

/// Tone placement through the engine (5.1 to 5.4).
@Suite("Composition: tone placement and relocation (5.1 to 5.4)")
struct TonePlacementCompositionTests {
    /// Spec 5.3: keys, traditional, modern.
    static let placementRows: [(String, String, String)] = [
        ("hoaf", "hòa", "hoà"), ("hoafn", "hoàn", "hoàn"), ("khoer", "khỏe", "khoẻ"), ("thuyr", "thủy", "thuỷ"),
        ("huyts", "huýt", "huýt"), ("huynhf", "huỳnh", "huỳnh"), ("xoays", "xoáy", "xoáy"),
        ("hoaif", "hoài", "hoài"), ("khuyur", "khuỷu", "khuỷu"), ("ngoeoj", "ngoẹo", "ngoẹo"),
        ("cuar", "của", "của"), ("mias", "mía", "mía"), ("muwaf", "mừa", "mừa"), ("tuooir", "tuổi", "tuổi"),
        ("ruwowuj", "rượu", "rượu"), ("hieeur", "hiểu", "hiểu"), ("khuyeenr", "khuyển", "khuyển"),
        ("hueej", "huệ", "huệ"), ("quys", "quý", "quý"), ("giuwax", "giữa", "giữa"), ("sooocs", "soóc", "soóc"),
    ]

    @Test func placementTable() throws {
        for (keys, traditional, modern) in Self.placementRows {
            #expect(try Typing.display(keys) == traditional, "\(keys)")
            #expect(try Typing.display(keys, Typing.modern) == modern, "\(keys) modern")
        }
    }

    @Test func relocationWhileTyping() throws {
        // 5.4 table.
        #expect(try Typing.display("hoaf") == "hòa")
        #expect(try Typing.display("hoaf", Typing.modern) == "hoà")
        #expect(try Typing.display("hoafn") == "hoàn")
        #expect(try Typing.display("gis") == "gí")
        #expect(try Typing.display("gisu") == "giú")
        #expect(try Typing.display("gisup") == "giúp")
        #expect(try Typing.display("hoafn⌫") == "hòa")
    }

    @Test func quAndGiOnsetsAgreeInBothStyles() throws {
        // ENG-R502.
        for keys in ["quys", "quar", "quowr", "giaf", "giuwax", "giuxa", "gieengs"] {
            #expect(try Typing.display(keys) == Typing.display(keys, Typing.modern), "\(keys)")
        }
    }
}

/// Horn handling for `u o` (5.5) and the ENG-R532 commit form.
@Suite("Composition: horn handling (5.5)")
struct HornCompositionTests {
    @Test func hornOnEitherLetterMeansBoth() throws {
        for keys in ["tuwong", "tuwowng", "tuowng"] { #expect(try Typing.display(keys) == "tương", "\(keys)") }
        #expect(try Typing.display("nguwow") == "ngươ")  // ENG-R531: open pair shown as ươ
        #expect(try Typing.display("thuow") == "thươ")
    }

    @Test func circumflexAndHornReplaceEachOther() throws {
        // ENG-R533 (REG-12).
        #expect(try Typing.display("cuwowio") == "cuôi")
        #expect(try Typing.display("cuwowiso") == "cuối")
        #expect(try Typing.display("cuooisw") == "cưới")
        // ENG-R534: a second w on a fully horned pair escapes.
        #expect(try Typing.display("thuoww") == "thuow")
    }

    @Test func commitFormOfAnOpenPair() throws {
        // ENG-R532, for section 8 to call.
        func committed(_ keys: String) throws -> String {
            let token = try #require(try Typing.driver(keys).state.active)
            return token.composition.committedText(style: .traditional)
        }
        #expect(try committed("thuowr") == "thuở")
        #expect(try committed("huow") == "huơ")
        #expect(try committed("Thuowr") == "Thuở")
        #expect(try committed("THUOWR") == "THUỞ")
        #expect(try committed("thuowng") == "thương")  // closed: unchanged
        #expect(try committed("nguwowif") == "người")  // ending: unchanged
        #expect(try committed("quowr") == "quở")
        #expect(try committed("thuowb") == "thươb")  // literal: the display is kept
    }
}

/// Options (4.8), escapes (4.7) and literal mode (4.5).
@Suite("Composition: options, escapes and literal mode (4.5 to 4.8)")
struct OptionAndEscapeTests {
    static let noStandaloneW = EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false)))
    static let brackets = EngineConfiguration(inputMethod: .telex(TelexOptions(bracketKeys: true)))

    @Test func standaloneWOff() throws {
        #expect(try Typing.display("w", Self.noStandaloneW) == "w")
        #expect(try Typing.display("tw", Self.noStandaloneW) == "tw")
        #expect(try Typing.display("tuw", Self.noStandaloneW) == "tư")
        #expect(try Typing.display("tuowng", Self.noStandaloneW) == "tương")
        #expect(try Typing.driver("tw", Self.noStandaloneW).state.isLiteral)
    }

    @Test func bracketKeysOn() throws {
        #expect(try Typing.display("[", Self.brackets) == "ơ")
        #expect(try Typing.display("]", Self.brackets) == "ư")
        #expect(try Typing.display("t[", Self.brackets) == "tơ")
        #expect(try Typing.display("t]ngf", Self.brackets) == "từng")
        #expect(try Typing.display("][", Self.brackets) == "ươ")
        // 4.8: doubling escapes, and the escape is sticky.
        #expect(try Typing.display("[[", Self.brackets) == "[")
        #expect(try Typing.display("]]", Self.brackets) == "]")
        #expect(try Typing.display("[[[", Self.brackets) == "[[")
        #expect(try Typing.display("t[[", Self.brackets) == "t[")
    }

    @Test func bracketKeysOffAreBoundaries() throws {
        // REG-15: brackets stay brackets by default.
        var driver = try Typing.driver("[[")
        #expect(driver.field.string == "[[" && driver.state.activeDisplay.isEmpty)
        driver = try Typing.driver("ba]]")
        #expect(driver.field.string == "ba]]" && driver.state.historyCount == 1)
        driver = try Typing.driver("a[", Typing.vni)
        #expect(driver.field.string == "a[" && driver.state.activeDisplay.isEmpty)
    }

    @Test func escapeIsStickyPerKind() throws {
        // ENG-R441.
        #expect(try Typing.display("boooong") == "booong")
        #expect(try Typing.display("booong") == "boong")
        #expect(try Typing.display("oooo") == "ooo")
        #expect(try Typing.display("dddd") == "ddd")
        #expect(try Typing.display("a111", Typing.vni) == "a11")
        #expect(try Typing.display("wW") == "W")  // ENG-R903: the escape letter takes the escaping key's case
        #expect(try Typing.display("asS") == "aS")
    }

    @Test func readingsOfDecision0102() throws {
        // VNI 7 and 8 escape only on their own modifier (ENG-R414).
        #expect(try Typing.display("a87", Typing.vni) == "ă7")
        #expect(try Typing.display("o78", Typing.vni) == "ơ8")
        #expect(try Typing.display("a88", Typing.vni) == "a8")
        // A bracket key escapes only its own letter.
        #expect(try Typing.display("[]", Self.brackets) == "ơ]")
        // A circumflex on the o of ươ removes the horn of a standalone ư too (ENG-R412, ENG-R533).
        #expect(try Typing.display("woo") == "uô")
        // The second w completes the stored pair (swallowed), the third escapes (ENG-R413, ENG-R534).
        #expect(try Typing.display("tuwow") == "tươ")
        #expect(try Typing.display("tuwoww") == "tuow")
    }

    @Test func doubledTransformEndsWithTheKey() throws {
        // ENG-T36 on hand-picked tokens.
        let telex = [
            ("a", "s"), ("a", "a"), ("a", "w"), ("d", "d"), ("tu", "w"), ("tuo", "w"), ("e", "e"), ("ow", "j"),
        ]
        for (token, key) in telex {
            #expect(try Typing.display(token + key + key).hasSuffix(key), "\(token)+\(key)+\(key)")
        }
        let vni = [("a", "1"), ("a", "6"), ("o", "7"), ("a", "8"), ("d", "9"), ("uo", "7"), ("e", "5")]
        for (token, key) in vni {
            #expect(try Typing.display(token + key + key, Typing.vni).hasSuffix(key), "VNI \(token)+\(key)+\(key)")
        }
    }

    @Test func doubledToneEndsWithTheKeyOverTheCorpus() throws {
        // ENG-T36 over every Tier A level-tone syllable, Telex O1 and VNI O1, for every tone key.
        let telexEngine = Engine(configuration: Typing.telex, resources: .empty)
        let vniEngine = Engine(configuration: Typing.vni, resources: .empty)
        var checked = 0
        for pair in SyllableTables.standardPairs where pair.tones.count == 6 {
            for (method, toneKeys, engine) in [
                (CorpusMethod.telex, Array("sfrxj"), telexEngine), (.vni, Array("12345"), vniEngine),
            ] {
                let keys = try #require(
                    KeySequenceGenerator.keys(
                        onset: pair.onset.spelling, rhyme: pair.rhyme.spelling, tone: .level, method: method,
                        order: .o1))
                for toneKey in toneKeys {
                    var session = Session(engine: engine)
                    for character in keys + String(toneKey) + String(toneKey) {
                        _ = session.handle(.key(KeyInput(character)))
                    }
                    #expect(session.state.activeDisplay.last == toneKey, "\(keys)+\(toneKey)+\(toneKey)")
                    checked += 1
                }
            }
        }
        #expect(checked > 10_000)
    }

    @Test func literalModeFreezesTheDisplay() throws {
        // ENG-R420, REG-19, REG-03.
        #expect(try Typing.display("password") == "pasword")
        #expect(try Typing.display("mother") == "mother")
        let driver = try Typing.driver("tsa")  // ENG-R432: a tone key before any vowel is a letter
        #expect(driver.state.activeDisplay == "tsa" && driver.state.isLiteral)
        #expect(try Typing.display("cana") == "cân")  // ENG-R431
    }

    @Test func noQuickTelexShortcuts() throws {
        // REG-04, ENG-R121.
        for keys in ["cc", "kkk", "nn", "tt", "gg", "TT", "pp", "qq", "uu"] {
            #expect(try Typing.display(keys) == keys, "\(keys)")
        }
    }

    @Test func toneRemovalWithoutVowelNeverCrashes() throws {
        // REG-01, REG-25, 7.3.
        #expect(try Typing.display("qqz") == "qqz")
        #expect(try Typing.display("Quzhou") == "Quzhou")
        #expect(try Typing.display("qut0", Typing.vni) == "qut0")
        #expect(try Typing.display("za") == "za")
        #expect(try Typing.display("dda") == "đa")  // REG-21
        #expect(try Typing.display("aszs") == "á")  // removal, then a new tone
    }
}
