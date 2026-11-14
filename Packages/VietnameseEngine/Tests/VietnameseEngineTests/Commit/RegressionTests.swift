// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.5: one test per regression REG-01 to REG-31, through the whole engine (composition, commit
/// with the 13.9 fixture resources, history), each named after its REG id.
@Suite("Regressions REG-01 to REG-31 (13.5)")
struct RegressionTests {
    private let vni = EngineConfiguration(inputMethod: .vni)

    private func text(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws -> String {
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
        var session = Session(engine: Engine(configuration: EngineConfiguration(), resources: Committing.fixtures))
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
        #expect(EngineConfiguration().autoRestore)
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
        var driver = EngineDriver(configuration: EngineConfiguration(), resources: Committing.fixtures)
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
        #expect(try text("thuyr ", EngineConfiguration(toneStyle: .modern)) == "thuỷ ")
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
        let brackets = EngineConfiguration(inputMethod: .telex(TelexOptions(bracketKeys: true)))
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
        let off = EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false)))
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

    @Test("REG-24 a tone comes back after deleting the escape letter")
    func reg24() throws {
        #expect(try Committing.driver("nhaamff⌫").field.string == "nhầm")
        #expect(try text("nhaamff⌫ ") == "nhầm ")
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
}
