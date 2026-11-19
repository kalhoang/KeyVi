// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Section 10.1: history, Backspace across boundaries (ENG-R1001 to ENG-R1004).
@Suite("History and Backspace across boundaries (10.1)")
struct HistoryTests {
    @Test(arguments: [" ", ", ", ". ", "  ", "; ", "! ", "' ", ") "])
    func reopenAcrossBoundaries(separator: String) throws {
        // ENG-R1002, REG-07: `chao` + separator, Backspace over the separator, `f` -> `chào`.
        let backspaces = String(repeating: KeyNotation.backspace, count: separator.count)
        var driver = try Committing.driver("chao" + separator + backspaces)
        #expect(driver.field.string == "chao", "\(separator.debugDescription)")
        #expect(driver.state.activeDisplay == "chao" && driver.state.activeRawKeys == "chao")
        // Every Backspace over a boundary character is passed to the app.
        #expect(driver.outputs.suffix(separator.count).allSatisfy { $0.action == .passThrough })
        try driver.type("f ")
        #expect(driver.field.string == "chào ")
    }

    @Test func backspaceOverASeparatorDoesNotReopenEarly() throws {
        // With `", "` the first Backspace removes the space only; the token is re-opened when the comma,
        // the last boundary character before it, is removed.
        var driver = try Committing.driver("chao, ⌫")
        #expect(driver.field.string == "chao," && driver.state.activeDisplay.isEmpty)
        try driver.send(.backspace)
        #expect(driver.field.string == "chao" && driver.state.activeDisplay == "chao")
        #expect(driver.outputs.last?.composingText == "chao")
    }

    @Test func backspaceContinuesIntoTheTokenAndPastItsStart() throws {
        // ENG-R1003.
        var driver = try Committing.driver("ban nam ⌫")
        #expect(driver.state.activeDisplay == "nam" && driver.state.historyCount == 1)
        try driver.send(KeyNotation.events("⌫⌫⌫"))
        #expect(driver.field.string == "ban " && driver.state.activeDisplay.isEmpty)
        try driver.send(.backspace)
        #expect(driver.field.string == "ban" && driver.state.activeDisplay == "ban" && driver.state.historyCount == 0)
        try driver.send(.backspace)
        #expect(driver.field.string == "ba")
        // 7.4 inside a re-opened token: `vieejt` + space, two Backspaces -> `việ` (the tone stays on ệ).
        driver = try Committing.driver("vieejt ⌫⌫")
        #expect(driver.field.string == "việ")
        try driver.type("t.")
        #expect(driver.field.string == "việt.")
    }

    @Test func reopenedTokenKeepsItsComposition() throws {
        // "with all its raw keys and flags": the tone moves as in a token that was never committed.
        #expect(try Committing.text("hoaf ⌫n ") == "hoàn ")
        #expect(try Committing.text("tieeng ⌫s ") == "tiếng ")
        #expect(try Committing.text("Vieet ⌫j ") == "Việt ")
        // A token kept with the ENG-R532 spelling re-opens as written on screen.
        var driver = try Committing.driver("thuowr ⌫")
        #expect(driver.state.activeDisplay == "thuở" && driver.field.string == "thuở")
        try driver.send(.backspace)
        #expect(driver.field.string == "thu")
        driver = try Committing.driver("thuowr ⌫ ")
        #expect(driver.field.string == "thuở " && driver.outputs.last?.action == .passThrough)
    }

    @Test func reopenedRestoredTokenShowsItsRawKeys() throws {
        // ENG-R704: re-opened in its restored state; committing again gives the same decision.
        var driver = try Committing.driver("text ⌫")
        #expect(driver.state.activeDisplay == "text" && driver.state.isLiteral)
        try driver.type(" ")
        #expect(driver.field.string == "text " && driver.outputs.last?.decision == .restored(.invalid))
        #expect(driver.outputs.last?.action == .passThrough)
        // Keys typed into it are appended verbatim; the commit decides on the new raw keys exactly as for
        // a token typed afresh (`texts` composes `tét` and is not English in the 13.9 fixtures: L7).
        driver = try Committing.driver("text ⌫s")
        #expect(driver.field.string == "texts")
        try driver.type(" ")
        #expect(driver.field.string == "tét " && driver.outputs.last?.decision == .kept(.notEnglish))
        #expect(try Committing.text("texts ") == "tét ")
        // A user-restored token re-opens restored and commits by L1 again.
        driver = try Committing.driver("vieejt⎋ ⌫ ")
        #expect(driver.field.string == "vieejt " && driver.outputs.last?.decision == .restored(.userChoice))
    }

    @Test func emptyHistoryBackspacePassesThrough() throws {
        // ENG-R1004.
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: Committing.fixtures)
        let output = try driver.send(.backspace)
        #expect(output.action == .passThrough && output.composingText.isEmpty && driver.state == .initial)
    }

    @Test func returnAndTabEndTheEditContext() throws {
        // ENG-R912: commit, then clear the history; Backspace deletes the newline in the app only.
        for hard in ["\n", "\t"] {
            var driver = try Committing.driver("chao" + hard + "⌫")
            #expect(driver.field.string == "chao" && driver.state.activeDisplay.isEmpty, "\(hard.debugDescription)")
            try driver.type("f")
            #expect(driver.field.string == "chaof")
        }
    }

    @Test func historyLimitComesFromTheConfiguration() throws {
        // ENG-R1001: default 16 tokens, oldest dropped, never a crash.
        let words = String(repeating: "ban ", count: 40)
        #expect(try Committing.driver(words).state.historyCount == 16)
        for limit in [1, 3, 16, 100] {
            let driver = try Committing.driver(words, EngineConfiguration(historyLimit: limit, typoCorrection: false))
            #expect(driver.state.historyCount == min(limit, 40), "limit \(limit)")
        }
        // Backspace walks back only over what the history holds, then passes through.
        var driver = try Committing.driver("ba nam ", EngineConfiguration(historyLimit: 1, typoCorrection: false))
        #expect(driver.state.historyCount == 1)
        try driver.send(KeyNotation.events("⌫⌫⌫⌫⌫"))  // space, m, a, n, space
        #expect(driver.field.string == "ba" && driver.state.activeDisplay.isEmpty)
        try driver.send(.backspace)
        #expect(driver.field.string == "b" && driver.state.activeDisplay.isEmpty)
    }

    @Test(arguments: [Int.max, Int.max / History.entriesPerToken + 1])
    func hugeHistoryLimitNeverTraps(limit: Int) throws {
        // ENG-R1001 ("never a crash"), ENG-T30: a host may pass a huge limit to mean "unlimited"; the
        // entry bound (limit x 64) saturates instead of overflowing on the first commit.
        #expect(History.entryLimit(forTokens: limit) == .max)
        var driver = try Committing.driver(
            "ban nam, ⌫⌫", EngineConfiguration(historyLimit: limit, typoCorrection: false))
        #expect(driver.field.string == "ban nam" && driver.state.activeDisplay == "nam")
        try driver.type(" ")
        #expect(driver.field.string == "ban nam " && driver.state.historyCount == 2)
        // The limit is a public property, so it can also be set after the initialiser; the fuzz checker
        // computes the same bound.
        var configuration = EngineConfiguration(typoCorrection: false)
        configuration.historyLimit = limit
        var checker = InvariantChecker(engine: Engine(configuration: configuration, resources: .empty))
        try checker.send(KeyNotation.events("ban nam  ⌫⌫⌫"))
        try checker.finish()
    }

    @Test func longBoundaryRunsStayBounded() throws {
        var session = Session(
            engine: Engine(
                configuration: EngineConfiguration(historyLimit: 2, typoCorrection: false), resources: .empty))
        for _ in 0..<5_000 { _ = session.handle(.key(KeyInput("!"))) }
        #expect(session.state.history.entries.count <= 2 * History.entriesPerToken)
        for _ in 0..<5_000 { _ = session.handle(.backspace) }
        #expect(session.state.history.entries.isEmpty)
    }
}

/// Section 10.2: every reset reason clears the token and the history and edits nothing.
@Suite("Resets (10.2)")
struct ResetTests {
    static let reasons: [ResetReason] = [
        .cursorMoved, .pointerClicked, .focusChanged, .applicationChanged, .inputSourceChanged, .secureInputChanged,
        .eventTapReenabled, .shortcut, .forwardDelete, .modeToggled, .configurationChanged, .unknown,
        .unseenInput,
    ]

    @Test(arguments: reasons)
    func resetClearsTokenAndHistory(reason: ResetReason) throws {
        // ENG-R1010 to ENG-R1012, ENG-R831, REG-18, REG-22.
        var driver = try Committing.driver("ban vieej")
        #expect(driver.state.historyCount == 1)
        let output = try driver.send(.reset(reason))
        #expect(output == EngineOutput(action: .passThrough, composingText: ""), "\(reason)")
        #expect(driver.state == .initial && driver.field.string == "ban việ")
        // Nothing is re-opened: Backspace passes through, the next key starts a fresh token.
        try driver.send(.backspace)
        #expect(driver.field.string == "ban vi" && driver.state.activeDisplay.isEmpty)
        try driver.type("ej ")
        #expect(driver.field.string == "ban viẹ ")
        // After a reset the run is new: no English run, no macro span from before.
        driver = try Committing.driver("and")
        try driver.send(.reset(reason))
        try driver.type(" this ")
        #expect(driver.field.string == "and thí ")
    }
}

/// Internal behaviour of `History` that the public events cannot reach directly.
@Suite("History internals")
struct HistoryInternalsTests {
    private func committed(_ keys: String) -> CommittedToken {
        let rules = ComposerRules(EngineConfiguration(typoCorrection: false))
        let composition = Composition(replaying: Array(keys.utf8), rules: rules)
        let display = composition.display(style: .traditional)
        let token = ActiveToken(composition: composition, display: display, userChoice: .none, restoredByRule: false)
        return CommittedToken(
            token: token, committedText: display, decision: .kept(.notEnglish), language: .vietnamese,
            languagesBefore: RecentLanguages())
    }

    @Test func equalityIgnoresTheHeadOffset() {
        // The same logical entries reached after many trims (compacted storage) and after a few (head
        // offset) are equal and hash equal.
        func history(rounds: Int) -> History {
            var history = History()
            for _ in 0..<rounds {
                history.record(committed("ban"), limit: 2)
                history.record(boundary: " ", limit: 2)
            }
            return history
        }
        let many = history(rounds: 100)
        var few = history(rounds: 3)
        // Trimming drops up to the oldest surplus token; the space after it stays.
        #expect(many.entries.count == 5 && many.tokenCount == 2 && many.startsMidSpan)
        #expect(many == few)
        #expect(Set([many, few]).count == 1)
        few.record(boundary: ",", limit: 2)
        #expect(many != few)
    }

    @Test func trimmingInsideASpanMarksTheStartUnknown() {
        // A macro span cannot reach back past entries that were dropped (ENG-R1102).
        var history = History()
        history.record(committed("x"), limit: 1)
        history.record(boundary: ".", limit: 1)
        history.record(committed("y"), limit: 1)
        #expect(history.startsMidSpan && history.tokenCount == 1)
        history.clear()
        #expect(!history.startsMidSpan && history.isEmpty)
    }

    @Test func backspaceWithATokenLastInTheHistory() {
        // Defensive path of ENG-R1003: a history that ends with a token (no boundary after it) re-opens the
        // token and deletes into it.
        let engine = Engine(configuration: EngineConfiguration(typoCorrection: false), resources: .empty)
        var state = EngineState.initial
        state.history.record(committed("vieejt"), limit: 16)
        let (next, output) = engine.reduce(state, .backspace)
        #expect(next.activeDisplay == "việ" && next.historyCount == 0)
        #expect(output.action == .passThrough && output.composingText == "việ")
    }

    @Test func capitalisingTextWithoutLetters() {
        #expect(MacroCase.capitalisingFirstLetter("...") == "...")
        #expect(MacroCase.capitalisingFirstLetter("") == "")
        #expect(MacroCase.capitalisingFirstLetter("ßx") == "SSx")
        #expect(MacroCase.capitalisingFirstLetter("日本") == "日本")
    }
}
