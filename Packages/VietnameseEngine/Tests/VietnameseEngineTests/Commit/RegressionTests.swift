// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.5: one test per regression REG-01 to REG-39, through the whole engine (composition, commit
/// with the 13.9 fixture resources, history), each named after its REG id.
@Suite("Regressions REG-01 to REG-39 (13.5)")
struct RegressionTests {
    private let vni = EngineConfiguration(inputMethod: .vni, typoCorrection: false)

    private func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration(typoCorrection: false))
        throws -> String
    {
        try Committing.text(keys, configuration)
    }

    @Test("REG-01 qu with tone removal and no vowel never crashes")
    func reg01() throws {
        for keys in ["quz", "QUZ", "qutz", "qqz", "Quzhou"] {
            #expect(try text(keys + " ") == keys + " ", "\(keys)")
        }
        for keys in ["qu0", "qut0"] { #expect(try text(keys + " ", vni) == keys + " ", "\(keys)") }
    }

    @Test("REG-02 tokens longer than 32 keys restore and commit exactly", arguments: [33, 64, 1_000, 100_000])
    func reg02(length: Int) {
        let keys = "as" + String(repeating: "t", count: length - 2)
        var session = Session(
            engine: Engine(configuration: EngineConfiguration(typoCorrection: false), resources: Committing.fixtures))
        for key in keys { _ = session.handle(.key(KeyInput(key))) }
        let output = session.handle(.key(KeyInput(" ")))
        // `át...` is not a syllable: L5 restores the raw keys, all of them.
        #expect(output.decision == .restored(.invalid))
        if case .edit(let edit, true) = output.action {
            #expect(edit.deleteCount == length - 1 && edit.insert == keys)
        } else {
            Issue.record("expected an edit then the space")
        }
        _ = session.handle(.backspace)
        #expect(session.state.activeRawKeys == keys)
    }

    @Test("REG-03 English restore is on by default and needs no download")
    func reg03() throws {
        #expect(EngineConfiguration(typoCorrection: false).autoRestore)
        for word in ["text", "user", "case", "wifi", "USB"] {
            #expect(try Committing.text(word + " ", resources: .empty) == word + " ", "\(word)")
        }
    }

    @Test("REG-04 no Quick Telex shortcuts")
    func reg04() throws {
        for keys in ["cc", "kkk", "nn", "tt", "gg", "TT", "pp", "qq", "uu"] {
            #expect(try text(keys + " ") == keys + " ", "\(keys)")
        }
    }

    @Test("REG-05 VNI restore reproduces the digits")
    func reg05() throws {
        #expect(try text("ba6c3 ", vni) == "ba6c3 ")  // B047
        #expect(try text("vie65t⎋", vni) == "vie65t")  // E03
        #expect(try text("vie65t ⌫⎋", vni) == "vie65t")
    }

    @Test("REG-06 output is NFC with precomposed letters only")
    func reg06() throws {
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: Committing.fixtures)
        try driver.send(KeyNotation.events("Vieetj Nam dduwowcj ngh thuowr huow quowrn DDawsk text ⌫ ⎋ "))
        for output in driver.outputs {
            guard case .edit(let edit, _) = output.action else { continue }
            #expect(edit.insert == edit.insert.precomposedStringWithCanonicalMapping)
            #expect(!edit.insert.unicodeScalars.contains { $0.properties.canonicalCombiningClass.rawValue != 0 })
        }
    }

    @Test("REG-07 Backspace across separators keeps the previous word")
    func reg07() throws {
        for separator in [" ", ", ", ". ", "  "] {
            let backspaces = String(repeating: "⌫", count: separator.count)
            #expect(try text("chao" + separator + backspaces + "f") == "chào", "\(separator.debugDescription)")
        }
    }

    @Test("REG-08 valid words and names are kept")
    func reg08() throws {
        let words = [
            ("Kroong", "Krông"), ("DDawsk", "Đắk"), ("Lawsk", "Lắk"), ("Pawsc", "Pắc"), ("Buoon", "Buôn"),
            ("Thuootj", "Thuột"), ("huow", "huơ"), ("huychs", "huých"), ("huychj", "huỵch"), ("pias", "pía"),
            ("gieecs", "giếc"), ("quowrn", "quởn"), ("toej", "tọe"), ("buyts", "buýt"),
        ]
        for (keys, word) in words { #expect(try text(keys + " ") == word + " ", "\(keys)") }
    }

    @Test("REG-09 tone and modifier keys after the coda")
    func reg09() throws {
        for (keys, word) in [("caanf", "cần"), ("hopwj", "hợp"), ("mootj", "một"), ("phucws", "phức"), ("tucj", "tục")]
        {
            #expect(try text(keys + " ") == word + " ", "\(keys)")
        }
        #expect(try text("vie6t5 ", vni) == "việt ")
        #expect(try text("duoc795 ", vni) == "được ")
    }

    @Test("REG-10 ddid commits did")
    func reg10() throws {
        let driver = try Committing.driver("ddid ")
        #expect(driver.field.string == "did " && driver.outputs.last?.decision == .kept(.escape))
    }

    @Test("REG-11 tone position for uy, xoáy and giúp")
    func reg11() throws {
        #expect(try text("thuyr ") == "thủy ")
        #expect(try text("thuyr ", EngineConfiguration(toneStyle: .modern, typoCorrection: false)) == "thuỷ ")
        #expect(try text("xoays ") == "xoáy ")
        #expect(try text("gisup ") == "giúp ")
        #expect(try text("gi1up ", vni) == "giúp ")
    }

    @Test("REG-12 ươ, uô and the second w")
    func reg12() throws {
        #expect(try text("thuow ") == "thuơ ")
        #expect(try text("cuwowiso ") == "cuối ")
        #expect(try text("cuooisw ") == "cưới ")
        #expect(try text("thuowng ") == "thương ")
        #expect(try Committing.driver("thuoww").field.string == "thuow")
    }

    @Test("REG-13 stretched words keep their marks")
    func reg13() throws {
        #expect(try Committing.driver("wfaaa").field.string == "ừaaa")
        #expect(try Committing.driver("nhesee").field.string == "nhée")
        #expect(try Committing.driver("chuwaa").field.string == "chưaa")
    }

    @Test("REG-14 VNI keeps shifted digits as symbols")
    func reg14() throws {
        #expect(try text("o@gmail.com ", vni) == "o@gmail.com ")
        #expect(try text("(d9a6y la2 vi1 du5)", vni) == "(đây là ví dụ)")
    }

    @Test("REG-15 brackets stay brackets by default")
    func reg15() throws {
        #expect(try text("[[ ]] a[b] ") == "[[ ]] a[b] ")
        let brackets = EngineConfiguration(inputMethod: .telex(TelexOptions(bracketKeys: true)), typoCorrection: false)
        #expect(try Committing.driver("[", brackets).field.string == "ơ")
        #expect(try Committing.driver("]", brackets).field.string == "ư")
    }

    @Test("REG-16 the engine sees characters, not key codes")
    func reg16() throws {
        // A QWERTZ user presses the key labelled Y, which produces `y`: the engine only sees `y`. The same
        // characters from any layout give the same text.
        let qwertzZ = KeyInput("z")  // physical Y on QWERTZ
        let qwertyZ = KeyInput("z")  // physical Z on QWERTY
        #expect(qwertzZ == qwertyZ)
        #expect(try text("zas ") == "zá ")
        #expect(try text("yeeus ") == "yếu ")
    }

    @Test("REG-17 ĐL is kept")
    func reg17() throws {
        #expect(try text("DDL ") == "ĐL ")
        #expect(try text("ddc ") == "đc ")
    }

    @Test("REG-18 the first word after re-focusing is restored")
    func reg18() throws {
        var driver = try Committing.driver("vieejt")
        try driver.send(.reset(.focusChanged))
        try driver.send(KeyNotation.events("verbose "))
        #expect(driver.field.string == "việtverbose ")
        #expect(driver.outputs.last?.decision == .restored(.invalid))
    }

    @Test("REG-19 an English word gets no second mark")
    func reg19() throws {
        #expect(try Committing.driver("password").field.string == "pasword")
        #expect(try text("password ") == "password ")
    }

    @Test("REG-20 w, qw and standalone w off")
    func reg20() throws {
        #expect(try Committing.driver("qw").field.string == "qw")
        for (keys, word) in [("hw", "hư"), ("thw", "thư"), ("chw", "chư")] {
            #expect(try Committing.driver(keys).field.string == word, "\(keys)")
        }
        let off = EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false)), typoCorrection: false)
        #expect(try Committing.driver("w", off).field.string == "w")
        #expect(try text("tuw ", off) == "tư ")
    }

    @Test("REG-21 dda gives đa")
    func reg21() throws {
        #expect(try text("dda ") == "đa ")
    }

    @Test("REG-22 a re-enabled event tap resets the engine")
    func reg22() throws {
        var driver = try Committing.driver("ban nam ")
        try driver.send(.reset(.eventTapReenabled))
        #expect(driver.state == .initial)
        try driver.send(KeyNotation.events("⌫f"))
        #expect(driver.field.string == "ban namf")  // nothing re-opened, no wrong deletion
    }

    @Test("REG-23 no logging or I/O in the core")
    func reg23() throws {
        // Static check over the core target's sources (ENG-R128, ENG-R1220, ENG-R1201, ENG-R1202): imports,
        // logging, I/O, clocks, randomness, environment and mutable global state (StaticSourceTests).
        let sources = try CoreSourceScanner.coreSources()
        #expect(sources.count > 10)
        for (name, text) in sources {
            for finding in CoreSourceScanner.scan(text, file: name) { Issue.record("\(finding)") }
        }
    }

    @Test("REG-24 the tone can be applied again after deleting the escape letter")
    func reg24() throws {
        // ENG-R711 as amended on 15/11/2026: Backspace takes the escape letter and the tone key it undid, so
        // the field loses one character and the next tone key applies (the tone kind is no longer escaped).
        #expect(try Committing.driver("nhaamff⌫").field.string == "nhâm")
        #expect(try Committing.driver("nhaamff⌫f").field.string == "nhầm")
        #expect(try text("nhaamff⌫f ") == "nhầm ")
        #expect(try text("nhaamff⌫ ") == "nhâm ")
    }

    @Test("REG-25 teencode z onset")
    func reg25() throws {
        #expect(try text("za ") == "za ")
        let driver = try Committing.driver("zas ")
        #expect(driver.field.string == "zá " && driver.outputs.last?.decision == .kept(.extendedSpelling))
    }

    @Test("REG-26 misspellings stay as typed")
    func reg26() throws {
        for keys in ["nghaxi", "nghoo"] {
            let driver = try Committing.driver(keys + " ")
            #expect(driver.field.string == keys + " " && driver.outputs.last?.decision == .kept(.unchanged))
        }
    }

    @Test("REG-27 restore keeps doubled letters")
    func reg27() throws {
        #expect(try Committing.driver("traffic").field.string == "trafic")
        #expect(try text("traffic ") == "traffic ")
        #expect(try text("traffic⎋") == "traffic")
    }

    @Test("REG-28 the dz onset composes and is kept")
    func reg28() throws {
        for (keys, word) in [("dzoo", "dzô"), ("dzaayj", "dzậy"), ("Dzui", "Dzui"), ("dzuwx", "dzữ"), ("dzif", "dzì")] {
            #expect(try text(keys + " ") == word + " ", "\(keys)")
        }
        #expect(try text("dzo6 ", vni) == "dzô ")
    }

    @Test("REG-29 hẹo is kept whatever the boundary and the data")
    func reg29() throws {
        for boundary in [" ", ",", ".", ";", ":", "!", "?", ")", "\n", "\t", "-", "'"] {
            #expect(try text("heoj" + boundary) == "hẹo" + boundary, "\(boundary.debugDescription)")
            #expect(try Committing.text("heoj" + boundary, resources: .empty) == "hẹo" + boundary)
        }
        // A dictionary without `hẹo` cannot restore it: the raw keys are not English (L7 before L8).
        let withoutHeo = Resources(
            english: WordSet(SpecFixtures.englishLexicon), techAlways: WordSet(SpecFixtures.techAlways),
            techCodeOnly: WordSet(SpecFixtures.techCodeOnly),
            attestedSyllables: WordSet(SpecFixtures.attestedSyllables.subtracting(["hẹo"])), ambiguity: [:],
            userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        for boundary in [" ", ","] {
            #expect(try Committing.text("heoj" + boundary, resources: withoutHeo) == "hẹo" + boundary)
            #expect(try Committing.decision("heoj" + boundary, resources: withoutHeo) == .kept(.notEnglish))
        }
    }

    @Test("REG-30 restore fires at punctuation, not only at Space")
    func reg30() throws {
        for (keys, boundary) in [
            ("text", ","), ("text", "."), ("user", ";"), ("wifi", "?"), ("case", "!"), ("USB", ")"), ("text", ":"),
            ("text", "\n"),
        ] {
            let driver = try Committing.driver(keys + boundary)
            #expect(driver.field.string == keys + boundary, "\(keys)\(boundary.debugDescription)")
            #expect(driver.outputs.last?.decision == .restored(.invalid))
        }
    }

    @Test("REG-31 Backspace never takes the horn off a letter it does not delete")
    func reg31() throws {
        // ENG-R710: one `w` (VNI `7`) marked both letters of `ươ`; deleting `ơ` keeps it for `ư`, inside the
        // word and after the word is re-opened (ENG-R1002), and the Backspace that deletes `ơ` passes
        // through (ENG-R712: the field loses exactly one character).
        for (keys, expected) in [
            ("thuowr⌫", "thư"), ("dduowcj⌫⌫", "đư"), ("truowngf⌫⌫⌫", "trư"), ("nguowif ⌫⌫⌫", "ngư"),
            ("Thuowng⌫⌫⌫", "Thư"), ("NGUOWIF ⌫⌫⌫", "NGƯ"),
        ] {
            let driver = try Committing.driver(keys)
            #expect(driver.field.string == expected, "\(keys)")
            #expect(driver.outputs.last?.action == .passThrough, "\(keys)")
        }
        #expect(try Committing.driver("thuo73⌫", vni).field.string == "thư")
        #expect(try Committing.driver("duo7c5 ⌫⌫⌫", vni).field.string == "dư")
        // ENG-R532: a re-opened `thuở` shows `uơ`; its `u` shows no horn, so it stays `u`.
        #expect(try Committing.driver("thuowr ⌫⌫").field.string == "thu")
    }

    @Test("REG-32 an English loanword in a Vietnamese sentence does not turn á into as")
    func reg32() throws {
        // ENG-R823 as amended by the product owner on 14/11/2026: `cũng` is in the window of the previous three
        // tokens, so the run is not English although `tricky` is; rule L11 keeps `á` (row `as` = vi).
        let keys = "Khusc caif cacs app caafn thieest treen win cungx tricky as."
        #expect(try text(keys) == "Khúc cài các app cần thiết trên win cũng tricky á.")
        #expect(try Committing.decision(keys) == .kept(.ambiguityTable))
        #expect(try text("dduwowcj as.") == "được á.")
        #expect(try text("as.") == "á.")
        // English stays English: only English in the window, or `Thí` (kept by L11, neutral) and then `is`.
        #expect(try text("tricky as ") == "tricky as ")
        #expect(try text("This is as ") == "Thí is as ")
    }

    @Test("REG-33 retyping a word re-opened after an automatic restore composes")
    func reg33() throws {
        // ENG-R1005: the product owner's traces of 15/11/2026; the first version kept the keys as typed.
        #expect(try text("tiesng ⌫⌫⌫⌫⌫eesn") == "tiến")
        #expect(try text("baas ⌫⌫⌫⌫aasm ") == "bấm ")
        #expect(try text("huux ⌫⌫w") == "hưu")
        // A user restore stays literal (ENG-R701).
        #expect(try text("vieejt⎋ ⌫⌫⌫⌫⌫eejt ") == "vieejt ")
    }

    @Test("REG-34 a second tone-removal press removes the marks")
    func reg34() throws {
        // ENG-R411 as amended on 15/11/2026: one layer per press.
        #expect(try Committing.driver("daauszz").field.string == "dau")
        #expect(try Committing.driver("daauszzz").field.string == "dauz")
        #expect(try Committing.driver("dduwowngfzz").field.string == "duong")
        // The commit keeps what the removal left (rule L4a, REG-39 below; until 18/11/2026 L5 restored the keys).
        #expect(try text("dduwowngfzz ") == "duong " && text("vieejtz ") == "viêt ")
        #expect(try Committing.driver("a6100", vni).field.string == "a")
        // Unchanged where nothing is marked: REG-01, REG-25 and the `dz` onset.
        #expect(try text("quz ") == "quz " && text("za ") == "za " && text("dzui ") == "dzui ")
    }

    @Test("REG-35 a code-only word after Vietnamese words keeps its Vietnamese display in the code context")
    func reg35() throws {
        // ENG-R850 as amended on 15/11/2026: the product owner's message in iTerm2 (code context).
        let code = EngineConfiguration(appContext: .code, typoCorrection: false)
        #expect(try Committing.text("Suwar looxi chinhs tar\"", code) == "Sửa lỗi chính tả\"")
        #expect(try Committing.text("moo tar ", code) == "mô tả ")
        // A command still keeps its keys at the start of a line and after a code word.
        #expect(try Committing.text("tar -xzf ", code) == "tar -xzf ")
        #expect(try Committing.text("sudo tar ", code) == "sudo tar ")
    }

    @Test("REG-36: a Vietnamese sentence typed in a terminal keeps no shell command at its start")
    func reg36() throws {
        // The product owner's retest in iTerm2, where the rules turn `lookaheadRevision` off (PLT-R357). `Tar` starts a
        // sentence: in sentence case at the line start and committed by a space, L9 leaves it to the rules after it,
        // at its own commit (ENG-R850 as amended by the product owner on 16/11/2026), whatever D29 says.
        let terminal = EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false)
        let sentence = try Committing.driver("Tar thuwr cais nayf ", terminal)
        #expect(sentence.field.string == "Tả thử cái này " && sentence.outputs.allSatisfy { $0.revision == nil })
        let d29Off = EngineConfiguration(
            appContext: .code, lookaheadRevision: false, lineStartRevision: false, typoCorrection: false)
        #expect(try Committing.text("Tar thuwr cais nayf ", d29Off) == "Tả thử cái này ")
        // Typed in lowercase, RV5 of ENG-R828 revises it once the next word is Vietnamese.
        #expect(try Committing.text("tar thuwr cais nayf ", terminal) == "tả thử cái này ")
        // Commands keep their keys.
        #expect(try Committing.text("tar xf ", terminal) == "tar xf ")
        #expect(try Committing.text("tar nhaatj.log ", terminal) == "tar nhật.log ")
        #expect(try Committing.text("tar\nthuwr ", terminal) == "tar\nthử ")
    }

    @Test("REG-37: an English word that hits an escape mid-word commits as typed")
    func reg37() throws {
        // The product owner's report of 17/11/2026: `leecher` showed `lêch`, the third `e` escaped the circumflex
        // and the commit kept `lecher`, because neither `lecher` nor `leecher` is in the lexicon (rule L4 as it was).
        // A display with two vowel groups that went on after the escape cannot be one Vietnamese syllable.
        #expect(try Committing.text("leecher ") == "leecher ")
        #expect(try Committing.text("cheeseburger, ") == "cheeseburger, ")
        // The deliberate escapes of Telex users stay: elongations, names, the escape examples of 4.7.
        #expect(try Committing.text("boooong ") == "booong ")
        #expect(try Committing.text("Kroong Anaa ") == "Krông Ana ")
        #expect(try Committing.text("ass ") == "as ")
        #expect(try Committing.text("www ") == "www ")
    }

    @Test("REG-38: a code-only command whose keys are not English keeps its keys in a terminal")
    func reg38() throws {
        // The product owner's decision of 18/11/2026: for a code-only word whose keys are not English (`chown`, `chơn` by
        // L7) L9 is evaluated right after L5, so it follows the line as `tar` does. Before, L7 decided first and
        // `sudo chown -R` gave `sudo chơn -R`.
        let terminal = EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false)
        #expect(try Committing.text("sudo chown -R ", terminal) == "sudo chown -R ")
        #expect(try Committing.text("ls; chown ", terminal) == "ls; chown ")
        #expect(try Committing.text("chown thuwr ", terminal) == "chơn thử ")
        // Vietnamese text and the general context keep the Vietnamese display.
        #expect(try Committing.text("tay chown ", terminal) == "tay chơn ")
        #expect(try Committing.text("sudo chown ") == "sudo chơn ")
    }

    @Test("REG-39: the text a tone-removal key left is kept at commit")
    func reg39() throws {
        // Q9, decided by the product owner on 18/11/2026: rule L4a keeps the display unless the raw keys are English.
        // Before, `duong` and `viêt` are not syllables, so L5 restored the keys typed.
        #expect(try text("dduwowngfzz ") == "duong ")
        #expect(try text("vieejtz ") == "viêt " && text("vieejtzz ") == "viet ")
        #expect(try text("daauszz ") == "dau ")
        #expect(try text("vie65t0 ", vni) == "viêt ")
        #expect(try Committing.decision("dduwowngfzz ") == .kept(.toneRemoval))
    }
}
