// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R906: a letter made by a Telex bracket key, a key without case, is uppercase when Caps Lock was on for
/// that key or when the token is an all-caps word (decision of the product owner, 13/11/2026,
/// docs/decisions/0005-pa-decisions-2026-11-13.md).
@Suite("Bracket letters under Caps Lock and in all-caps words (ENG-R906)")
struct BracketCaseTests {
    static let brackets = EngineConfiguration(
        inputMethod: .telex(TelexOptions(bracketKeys: true)), typoCorrection: false)

    /// Types `keys` with Caps Lock on: letters arrive uppercase, as the host delivers them (ENG-R902), and every
    /// key carries the Caps Lock state. `⌫` is Backspace.
    static func typedWithCapsLock(_ keys: String) throws -> EngineDriver {
        var driver = EngineDriver(configuration: brackets)
        for key in keys {
            if key == "⌫" {
                try driver.send(.backspace)
            } else {
                try driver.send(.key(KeyInput(Character(key.uppercased()), capsLock: true)))
            }
        }
        return driver
    }

    @Test func keyInputCarriesTheCapsLockState() {
        #expect(KeyInput("[").capsLock == false)
        #expect(KeyInput("[", capsLock: true).capsLock)
        #expect(KeyInput("[", capsLock: true) != KeyInput("["))
    }

    @Test func capsLockMakesBracketLettersUppercase() throws {
        #expect(try Self.typedWithCapsLock("[").field.string == "Ơ")
        #expect(try Self.typedWithCapsLock("]").field.string == "Ư")
        #expect(try Self.typedWithCapsLock("t[").field.string == "TƠ")
        #expect(try Self.typedWithCapsLock("[i").field.string == "ƠI")
        #expect(try Self.typedWithCapsLock("t]ngf").field.string == "TỪNG")
        #expect(try Self.typedWithCapsLock("][").field.string == "ƯƠ")
        // The doubling escape still gives the literal bracket (4.8).
        #expect(try Self.typedWithCapsLock("[[").field.string == "[")
    }

    @Test func allCapsWordMakesBracketLettersUppercase() throws {
        #expect(try Typing.display("TH[", Self.brackets) == "THƠ")
        #expect(try Typing.display("TR]", Self.brackets) == "TRƯ")
        #expect(try Typing.display("T[I", Self.brackets) == "TƠI")
        #expect(try Typing.display("NG]OWIF", Self.brackets) == "NGƯỜI")
        #expect(try Typing.display("CH]A", Self.brackets) == "CHƯA")
    }

    @Test func otherwiseBracketLettersStayLowercase() throws {
        #expect(try Typing.display("[", Self.brackets) == "ơ")
        #expect(try Typing.display("t[", Self.brackets) == "tơ")
        #expect(try Typing.display("Th[", Self.brackets) == "Thơ")
        #expect(try Typing.display("T[", Self.brackets) == "Tơ")
        #expect(try Typing.display("[i", Self.brackets) == "ơi")
        // One other letter with a case is not an all-caps word.
        #expect(try Typing.display("[I", Self.brackets) == "ơI")
        #expect(try Typing.display("tH[", Self.brackets) == "tHơ")
        // Caps Lock affects only keys without case: the host already delivered letters in their case.
        var driver = EngineDriver(configuration: Self.brackets)
        try driver.send(.key(KeyInput("t", capsLock: true)))
        #expect(driver.field.string == "t")
    }

    @Test func caseFollowsTheCurrentLetters() throws {
        var driver = EngineDriver(configuration: Self.brackets)
        try driver.type("T[")
        #expect(driver.field.string == "Tơ")
        try driver.type("I")
        #expect(driver.field.string == "TƠI")
        try driver.type("⌫")
        #expect(driver.field.string == "Tơ")
    }

    @Test func backspaceAndReplayKeepTheCapsLockState() throws {
        // ENG-R601: the Caps Lock state of a bracket key is input, so the replay after Backspace keeps it.
        // `TỚ` is no all-caps word (one other letter), so only the recorded state keeps `Ớ` uppercase.
        let driver = try Self.typedWithCapsLock("t[sn⌫")
        #expect(driver.field.string == "TỚ")
        let token = try #require(driver.state.active)
        let replayed = Composition(
            replaying: token.composition.raw, capsLockKeys: token.composition.capsLockKeys,
            rules: ComposerRules(Self.brackets))
        #expect(replayed == token.composition)
    }

    @Test func commitWritesTheUppercaseLetter() throws {
        var driver = try Self.typedWithCapsLock("[ ")
        #expect(driver.field.string == "Ơ ")
        driver = try Typing.driver("TH[ ", Self.brackets)
        #expect(driver.field.string == "THƠ ")
        // Restore stays exact: the raw keys, brackets included (ENG-T32).
        driver = try Self.typedWithCapsLock("t[")
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "T[")
    }
}
