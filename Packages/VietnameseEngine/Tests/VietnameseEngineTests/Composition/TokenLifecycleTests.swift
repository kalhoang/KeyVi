// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Case (9.1), boundary classification (9.2), resets (10.2) and long tokens (6.5). The commit decision
/// itself is tested in Commit/.
@Suite("Composition: case (9.1)")
struct CaseTests {
    @Test func outputLettersTakeTheCaseOfTheirKeys() throws {
        // ENG-R901 to ENG-R903 (W201-W210 cover the rows of the spec).
        #expect(try Typing.display("Vieetj") == "Việt")
        #expect(try Typing.display("vIEETJ") == "vIỆT")
        #expect(try Typing.display("DDaf") == "Đà")
        #expect(try Typing.display("dDaf") == "đà")
        #expect(try Typing.display("TieengS") == "Tiếng")
        #expect(try Typing.display("W") == "Ư")
        #expect(try Typing.display("Aas") == "Ấ")
        #expect(try Typing.display("NGUWOWIF") == "NGƯỜI")
        #expect(try Typing.display("Duo7c5", Typing.vni) == "Dược")
    }

    @Test func camelCaseGoesLiteral() throws {
        // ENG-R904.
        #expect(try Typing.display("useState") == "ueState")
        #expect(try Typing.display("iPhone") == "iPhone")
        #expect(try Typing.display("MacBook") == "MacBook")
        #expect(try Typing.display("VnExpress") == "VnExpress")
        let camel = try Typing.driver("tHas")  // would compose to tHá without the rule
        #expect(camel.state.activeDisplay == "tHas" && camel.state.isLiteral)
        #expect(try #require(camel.state.active).composition.isCamelCase)
        #expect(try #require(try Typing.driver("useState").state.active).composition.isCamelCase)
    }

    @Test func invertedCapsAndTransformCaseAreNotCamelCase() throws {
        // ENG-R904: `tIẾNG` stays Vietnamese; ENG-R902: transform keys' case does not count.
        let inverted = try Typing.driver("tIEENGS")
        #expect(inverted.state.activeDisplay == "tIẾNG")
        #expect(try #require(inverted.state.active).composition.isCamelCase == false)
        #expect(try #require(try Typing.driver("dDaf").state.active).composition.isCamelCase == false)
        #expect(try #require(try Typing.driver("TieengS").state.active).composition.isCamelCase == false)
    }

    @Test func backspaceRestoresTheCamelState() throws {
        // Dropping the key that completed the pattern undoes it (replay equivalence).
        let driver = try Typing.driver("tHas⌫⌫")
        #expect(driver.state.activeDisplay == "tH")
        #expect(try #require(driver.state.active).composition.isCamelCase == false)
    }
}

@Suite("Composition: boundaries and resets (9.2, 10.2)")
struct BoundaryAndResetTests {
    @Test func boundaryCommitsAndPassesThrough() throws {
        // ENG-R910: a kept token leaves its display and the boundary key passes through.
        var driver = try Typing.driver("vieejt ")
        #expect(driver.field.string == "việt ")
        #expect(driver.state.activeDisplay.isEmpty && driver.state.historyCount == 1)
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.outputs.last?.composingText == "")
        try driver.type("nam,")
        #expect(driver.field.string == "việt nam,")
        #expect(driver.state.historyCount == 2)
    }

    @Test func boundaryKeysOfSection9() throws {
        let boundaries: [Character] = [
            " ", ".", ",", ";", ":", "!", "?", "'", "\"", "-", "/", "\\", "@", "#", "(", ")",
            "{", "}", "<", ">", "_", "=", "+", "*", "&", "%", "$", "^", "~", "`", "|", "é", "ß", "ư", "\u{00A0}",
        ]
        for boundary in boundaries {
            var driver = try Typing.driver("vieejt")
            try driver.send(.key(KeyInput(boundary)))
            #expect(driver.state.activeDisplay.isEmpty, "\(boundary) should end the token")
            #expect(driver.field.string == "việt" + String(boundary))
        }
    }

    @Test func digitsByMethod() throws {
        // 9.2: digits are boundaries in Telex, transforms in VNI; keypad digits are boundaries in both
        // (ENG-R401); shifted digits arrive as symbols (ENG-R402, REG-14).
        var telex = try Typing.driver("a1")
        #expect(telex.state.activeDisplay.isEmpty && telex.field.string == "a1")
        var vni = EngineDriver(configuration: Typing.vni)
        try vni.type("a")
        try vni.send(.key(KeyInput("1", fromKeypad: true)))
        #expect(vni.state.activeDisplay.isEmpty && vni.field.string == "a1")
        vni = try Typing.driver("o@gmail.com", Typing.vni)
        #expect(vni.field.string == "o@gmail.com")
        vni = try Typing.driver("(d9a6y la2 vi1 du5)", Typing.vni)
        #expect(vni.field.string == "(đây là ví dụ)")
        telex = try Typing.driver("vieejt", Typing.vni)  // W200: Telex keys in VNI are letters
        #expect(telex.field.string == "vieejt")
    }

    @Test func returnAndTabClearTheHistory() throws {
        // ENG-R912.
        for hard in ["\n", "\t", "\r"] {
            var driver = try Typing.driver("ban ")
            #expect(driver.state.historyCount == 1)
            try driver.type("nam" + hard)
            #expect(driver.state.historyCount == 0, "\(hard.debugDescription)")
            #expect(driver.field.string == "ban nam" + hard)
        }
    }

    @Test func resetDropsTokenAndHistory() throws {
        // ENG-R1011, ENG-R1012, REG-18, REG-22.
        var driver = try Typing.driver("ban vie")
        let output = try driver.send(.reset(.eventTapReenabled))
        #expect(output.action == .passThrough && output.composingText.isEmpty)
        #expect(driver.state == .initial)
        try driver.type("ej")
        #expect(driver.state.activeDisplay == "ẹ")  // a fresh token, not `việ`
        #expect(driver.field.string == "ban vieẹ")
    }

    @Test func historyIsBounded() throws {
        // ENG-R1001: older entries are dropped; runs of boundaries cannot grow without bound.
        let engine = Engine(configuration: EngineConfiguration(historyLimit: 3), resources: .empty)
        var session = Session(engine: engine)
        for _ in 0..<50 {
            for key in "ba " { _ = session.handle(.key(KeyInput(key))) }
        }
        #expect(session.state.historyCount == 3)
        for _ in 0..<10_000 { _ = session.handle(.key(KeyInput(" "))) }
        #expect(session.state.history.entries.count <= 3 * History.entriesPerToken)
        #expect(EngineConfiguration(historyLimit: 0).historyLimit == 1)
    }

    @Test func backspaceEmptiesTheToken() throws {
        let driver = try Typing.driver("a⌫⌫")
        #expect(driver.state.active == nil && driver.field.string.isEmpty)
        #expect(driver.outputs.allSatisfy { $0.action == .passThrough })
    }
}

/// ENG-R640, ENG-R641, REG-02: no fixed limits; long tokens stay exact.
@Suite("Composition: long tokens (6.5)")
struct LongTokenTests {
    @Test func composingTokenGoesLiteralAfter64Keys() throws {
        // `sz` pairs keep composing; key 64 enters literal mode (ENG-R641).
        let keys = "a" + String(repeating: "sz", count: 32)
        var driver = try Typing.driver(String(keys.dropLast()))
        #expect(driver.state.activeDisplay == "á" && !driver.state.isLiteral)
        try driver.type("z")
        #expect(driver.state.activeDisplay == "áz" && driver.state.isLiteral)
        try driver.send(.backspace)
        #expect(driver.state.activeDisplay == "á" && !driver.state.isLiteral)
        try driver.send(.restoreToggle)
        #expect(driver.field.string == String(keys.dropLast()))  // restore is exact
    }

    @Test(arguments: [33, 64, 65, 1_000, 100_000])
    func longLiteralTokenRestoresExactly(length: Int) {
        let keys = "as" + String(repeating: "b", count: length - 2)
        let engine = Engine(configuration: EngineConfiguration(), resources: .empty)
        var session = Session(engine: engine)
        for key in keys { _ = session.handle(.key(KeyInput(key))) }
        #expect(session.state.activeDisplay.unicodeScalars.count == length - 1)  // "áb..."
        let output = session.handle(.restoreToggle)
        #expect(session.state.activeDisplay == keys)
        if case .edit(let edit, _) = output.action {
            #expect(edit.deleteCount == length - 1 && edit.insert == keys)
        } else {
            Issue.record("restore toggle should edit")
        }
        for _ in 0..<length { _ = session.handle(.backspace) }
        #expect(session.state.active == nil)
    }
}
