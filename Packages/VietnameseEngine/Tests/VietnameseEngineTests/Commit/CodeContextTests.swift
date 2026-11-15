// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Rule L9 follows the line, not the app (ENG-R850 as amended on 15/11/2026, REG-35): in the code context a
/// code-only word whose raw keys are English is restored unless it is in Vietnamese text, which the rules after
/// L9 decide exactly as in the general context. 13.9 fixtures: the code-only list holds `tar` and `sudo`, and
/// `tar` has no ambiguity row, so a token that L9 leaves alone is kept by L11 (`defaultVietnamese`).
@Suite("Rule L9 follows the line (ENG-R850, REG-35)")
struct CodeContextTests {
    static let code = EngineConfiguration(appContext: .code)
    static let codeWithoutRevision = EngineConfiguration(appContext: .code, lookaheadRevision: false)

    /// Keys and the field they leave in the code context when L9 restores the last token: at the start of
    /// the input or of a line, after an English word, after a code word shown as typed, after a code
    /// character, and when no Vietnamese word stands among the previous three tokens of the line.
    static let restored: [(keys: String, text: String)] = [
        ("tar ", "tar "),
        ("and tar ", "and tar "),
        ("sudo tar ", "sudo tar "),
        ("vieejt sudo tar ", "việt sudo tar "),
        ("vieejt and tar ", "việt and tar "),
        ("tar tar ", "tar tar "),
        ("vieejt `tar ", "việt `tar "),
        ("vieejt\" | tar ", "việt\" | tar "),
        ("vieejt && tar ", "việt && tar "),
        ("vieejt $tar ", "việt $tar "),
        ("vieejt\ntar ", "việt\ntar "),
        ("vieejt\ttar ", "việt\ttar "),
        ("vieejt ⟲tar ", "việt tar "),
        ("vieejt a a a tar ", "việt a a a tar "),
        ("ANH tar ", "ANH tar "),
        // A word glued to the previous one with no space between them is a code join (a file, directory or
        // user name), not Vietnamese text: `anh.tar.gz`, `anh/tar`, `minh@host`.
        ("anh.tar ", "anh.tar "),
        ("anh/tar ", "anh/tar "),
        ("anh-tar ", "anh-tar "),
        ("anh@tar ", "anh@tar "),
        ("anh:tar ", "anh:tar "),
        ("vieejt.tar ", "việt.tar "),
        ("vieejt anh.tar ", "việt anh.tar "),
    ]

    /// Keys and the field they leave when the last token is in Vietnamese text: a Vietnamese word (a
    /// Vietnamese-only letter, or a Vietnamese syllable typed unchanged) among the previous three tokens of the
    /// line, the previous token neither English nor a code word, and no code character after it.
    static let vietnamese: [(keys: String, text: String)] = [
        ("vieejt tar ", "việt tả "),
        ("chinhs tar\"", "chính tả\""),
        ("Suwar looxi chinhs tar\"", "Sửa lỗi chính tả\""),
        ("moo tar ", "mô tả "),
        ("anh tar ", "anh tả "),
        ("vieejt a tar ", "việt a tả "),
        ("vieejt a a tar ", "việt a a tả "),
        ("khoong there tar ", "không thể tả "),
        ("vieejt (tar ", "việt (tả "),
        ("vieejt \"tar ", "việt \"tả "),
        ("vieejt: tar ", "việt: tả "),
        ("vieejt. tar ", "việt. tả "),
        ("vieejt, tar ", "việt, tả "),
        ("vieejt - tar ", "việt - tả "),
        ("vieejt; tar ", "việt; tả "),
        ("vieejt.\u{00A0}tar ", "việt.\u{00A0}tả "),
    ]

    @Test("L9 restores outside Vietnamese text, with and without lookaheadRevision")
    func restoresOutsideVietnameseText() throws {
        for configuration in [Self.code, Self.codeWithoutRevision] {
            for (keys, text) in Self.restored {
                let driver = try Committing.driver(keys, configuration)
                #expect(driver.field.string == text, "\(keys.debugDescription)")
                #expect(driver.outputs.last?.decision == .restored(.codeContext), "\(keys.debugDescription)")
            }
        }
    }

    @Test("In Vietnamese text L9 does not apply and L11 keeps the Vietnamese display")
    func keepsVietnameseText() throws {
        for configuration in [Self.code, Self.codeWithoutRevision] {
            for (keys, text) in Self.vietnamese {
                let driver = try Committing.driver(keys, configuration)
                #expect(driver.field.string == text, "\(keys.debugDescription)")
                #expect(driver.outputs.last?.decision == .kept(.defaultVietnamese), "\(keys.debugDescription)")
            }
        }
    }

    @Test("The boundary key that ends the word is not evidence (P0-3, 13.9.1)")
    func boundaryAfterTheWordIsNotEvidence() throws {
        for boundary in [" ", "\"", "'", "`", "|", "&", "$", ")", "]", ".", ",", ":", "!", "\n", "\t"] {
            #expect(try Committing.text("chinhs tar" + boundary, Self.code) == "chính tả" + boundary, "\(boundary)")
            #expect(try Committing.text("tar" + boundary, Self.code) == "tar" + boundary, "\(boundary)")
            #expect(try Committing.decision("tar" + boundary, Self.code) == .restored(.codeContext), "\(boundary)")
        }
    }

    @Test("The general context never reaches L9")
    func generalContext() throws {
        for keys in ["tar ", "sudo tar ", "and `tar "] {
            #expect(try Committing.decision(keys) != .restored(.codeContext), "\(keys)")
        }
        #expect(try Committing.text("sudo tar ") == "sudo tả ")
    }

    @Test("ENG-R802: with auto restore off L9 names itself and keeps; in Vietnamese text L11 decides")
    func autoRestoreOff() throws {
        let off = EngineConfiguration(autoRestore: false, appContext: .code)
        #expect(try Committing.text("tar ", off) == "tả ")
        #expect(try Committing.decision("tar ", off) == .kept(.codeContext))
        #expect(try Committing.decision("vieejt tar ", off) == .kept(.defaultVietnamese))
    }

    @Test("A re-opened token is decided by the line before it, like any token (ENG-R1005)")
    func reopenedToken() throws {
        #expect(try Committing.text("vieejt tar ⌫ ", Self.code) == "việt tả ")
        #expect(try Committing.decision("vieejt tar ⌫ ", Self.code) == .kept(.defaultVietnamese))
        #expect(try Committing.text("tar ⌫ ", Self.code) == "tar ")
        #expect(try Committing.decision("tar ⌫ ", Self.code) == .restored(.codeContext))
    }

    @Test("A code word that composed Vietnamese is a Vietnamese word, not a code word")
    func codeWordShowingVietnamese() throws {
        // `chown` is code-only but not English, so L7 keeps `chơn`; on screen it is a Vietnamese word.
        let resources = Resources(
            english: WordSet(SpecFixtures.englishLexicon), techAlways: WordSet(SpecFixtures.techAlways),
            techCodeOnly: WordSet(SpecFixtures.techCodeOnly + ["chown"]),
            attestedSyllables: WordSet(SpecFixtures.attestedSyllables), ambiguity: [:], userKeepRaw: WordSet([]),
            userKeepVietnamese: WordSet([]))
        #expect(try Committing.text("chown tar ", Self.code, resources: resources) == "chơn tả ")
    }
}
