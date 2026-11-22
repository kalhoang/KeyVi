// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The context of a correction (ENG-R1112): never in `code`, committed only by whitespace, Return, Tab or an ASCII
/// closer of prose, and nothing glued before the word, at the start of a line too.
@Suite("Typo correction: context (ENG-R1112)")
struct TypoCorrectionContextTests {
    @Test func neverInTheCodeContext() throws {
        let driver = try Typo.typed("androdi ", appContext: .code)  // S65
        #expect(driver.field.string == "androdi ")
        #expect(driver.lastDecision == .kept(.unchanged))
        #expect(try Typo.field("echo androdi ", appContext: .code) == "echo androdi ")
    }

    @Test func onlyWhitespaceReturnTabAndTheAsciiClosersCommitACorrection() throws {
        #expect(try Typo.field("androdi.") == "android.")  // S25
        #expect(try Typo.field("(androdi)") == "(android)")  // S28
        for closer in [",", ";", ":", "!", "?", "]", "}", "\""] {
            #expect(try Typo.field("androdi" + closer) == "android" + closer, "\(closer)")
        }
        // S26 and Tab: Q11 (`CorrectionPolicy.commitKeys`).
        #expect(try Typo.field("androdi\n") == Typo.underQ11(corrected: "android\n", typed: "androdi\n"))
        #expect(try Typo.field("androdi\t") == Typo.underQ11(corrected: "android\t", typed: "androdi\t"))
        #expect(try Typo.field("androdi\r") == Typo.underQ11(corrected: "android\r", typed: "androdi\r"))
        // S80, S64 and the characters of identifiers, paths and links leave the token as decided.
        #expect(try Typo.field("androdi…") == "androdi…")
        #expect(try Typo.field("weren't") == "weren't")  // `wren` would fit
        #expect(try Typo.field("androdi’") == "androdi’")
        #expect(try Typo.field("androdi”") == "androdi”")
        for key in [
            "/", "@", "\\", "-", "_", "#", "~", "`", "|", "&", "$", "=", "+", "*", "%", "^", "<", ">", "(", "[",
            "{", "2", "\u{00A0}",
        ] {
            #expect(try Typo.field("androdi" + key) == "androdi" + key, "\(key)")
        }
    }

    @Test func nothingGluedBeforeTheWord() throws {
        #expect(try Typo.field("www.exapmle.com") == "www.exapmle.com")  // S59
        #expect(try Typo.field("kal@exapmle.com") == "kal@exapmle.com")  // S60
        #expect(try Typo.field("/opt/locla ") == "/opt/locla ")  // S61
        #expect(try Typo.field("#androdi ") == "#androdi ")  // S62: at a line start too
        #expect(try Typo.field("well-knwon ") == "well-knwon ")  // S63
        #expect(try Typo.field("ddi #androdi ") == "đi #androdi ")  // S81
        #expect(try Typo.field("2androdi ") == "2androdi ")
        #expect(try Typo.field("ok\n#androdi ") == "ok\n#androdi ")
        // A space or an opener before the word: corrected.
        #expect(try Typo.field("- androdi ") == "- android ")  // S29
        #expect(try Typo.field("# androdi ") == "# android ")  // S82
        #expect(try Typo.field("ok\n# androdi ") == "ok\n# android ")
        #expect(try Typo.field("> androdi ") == "> android ")
        #expect(try Typo.field("\"androdi\" ") == "\"android\" ")
        #expect(try Typo.field("[androdi] ") == "[android] ")
        #expect(try Typo.field("“androdi ") == "“android ")
        #expect(try Typo.field("‘androdi ") == "‘android ")
        #expect(try Typo.field("'androdi ") == "'android ")
        #expect(try Typo.field("ddi\u{00A0}androdi ") == "đi\u{00A0}android ")
        // The first word of a line and of an indented line.
        #expect(try Typo.field("ok\nandrodi ") == "ok\nandroid ")
        #expect(try Typo.field("ok\n  androdi ") == "ok\n  android ")
        #expect(try Typo.field("ok\tandrodi ") == "ok\tandroid ")
    }

    /// Review Focus 2 and ADR 0010 item 3: after a click or a focus change the history is empty, so a word typed
    /// right after a `#`, `@` or `/` the engine never saw is a candidate (the blind spot rule L9 already has,
    /// ENG-R850). Pinned, not fixed; listed under Known issues.
    @Test func afterAResetTheWordIsACandidate() throws {
        var driver = EngineDriver(configuration: Typo.configuration(), resources: Typo.resources)
        try driver.type("#")
        try driver.send(.reset(.pointerClicked))
        try driver.type("androdi ")
        #expect(driver.field.string == "#android ")
        #expect(driver.lastDecision == .corrected(.unchanged))
        // Without the reset the engine saw the `#`.
        #expect(try Typo.field("#androdi ") == "#androdi ")
    }
}
