// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The undo of a correction with the restore toggle, the history and the re-opening of a corrected token
/// (ENG-R1117, ENG-R1118), rows S66 to S73 of 13.12 with the correction fixture.
@Suite("Typo correction: undo, history and re-opening (ENG-R1117, ENG-R1118)")
struct TypoCorrectionUndoTests {
    @Test func theToggleRightAfterACorrectionBringsTheKeysBackAndTeaches_ENGR1117() throws {
        let driver = try Typo.typed("androdi ⎋")  // S68
        #expect(driver.field.string == "androdi ")
        let toggle = try #require(driver.outputs.last)
        // One edit over the correction and the boundary, minimal (ENG-R611): `id ` becomes `di `.
        #expect(
            toggle.action == .edit(TextEdit(deleteCount: 3, deleteUTF16Count: 3, insert: "di "), thenPassThrough: false)
        )
        #expect(toggle.learning == .neverCorrect(raw: "androdi"))
        #expect(toggle.decision == nil && toggle.revision == nil)
        // The history token now shows the raw keys as the user's choice.
        let token = try #require(driver.state.history.token(beforeNewest: 1))
        #expect(token.committedText == "androdi")
        #expect(token.decision == .restored(.userChoice))
        #expect(token.token.userChoice == .restored)
        #expect(token.language == .english)
    }

    @Test func aSecondTogglePassesThrough_ENGR702() throws {
        let driver = try Typo.typed("androdi ⎋⎋")  // S69
        #expect(driver.field.string == "androdi ")
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.learningSignals == [.neverCorrect(raw: "androdi")])
    }

    /// Review Focus 1: `androdi.` gives `android.`; the toggle right after gives `androdi.` with the `.` kept.
    @Test func undoAfterACloserKeepsTheCloser() throws {
        let driver = try Typo.typed("androdi.⎋")
        #expect(driver.field.string == "androdi.")
        #expect(
            driver.outputs.last?.action
                == .edit(TextEdit(deleteCount: 3, deleteUTF16Count: 3, insert: "di."), thenPassThrough: false))
        #expect(driver.learningSignals == [.neverCorrect(raw: "androdi")])
        #expect(try Typo.field("(androdi)⎋") == "(androdi)")
    }

    /// ENG-R1117, ENG-R829: Return and Tab clear the history, so the toggle passes through (Q11 decides whether
    /// Return corrected at all).
    @Test func afterReturnTheToggleCannotUndo() throws {
        for key in ["\n", "\t"] {
            let driver = try Typo.typed("androdi" + key + "⎋")
            #expect(driver.field.string == Typo.underQ11(corrected: "android", typed: "androdi") + key)
            #expect(driver.outputs.last?.action == .passThrough)
            #expect(driver.learningSignals.isEmpty)
        }
    }

    @Test func backspaceReopensTheCorrectionAsALiteralToken() throws {
        var driver = try Typo.typed("androdi ⌫")
        #expect(driver.state.activeDisplay == "android")
        #expect(driver.state.isLiteral)
        try driver.send(.backspace)  // S70
        #expect(driver.field.string == "androi")
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.state.isLiteral && driver.state.activeDisplay == "androi")
    }

    @Test func theToggleAfterReopeningBringsTheKeysBackWithTheSignal() throws {
        let driver = try Typo.typed("androdi ⌫⎋")  // S71
        #expect(driver.field.string == "androdi")
        #expect(driver.outputs.last?.learning == .neverCorrect(raw: "androdi"))
        #expect(driver.state.activeRawKeys == "androdi" && driver.state.isLiteral)
        // After Backspaces into the correction the toggle still brings the keys as typed back.
        let shortened = try Typo.typed("androdi ⌫⌫⌫⎋")
        #expect(shortened.field.string == "androdi")
        #expect(shortened.learningSignals == [.neverCorrect(raw: "androdi")])
    }

    @Test func aReopenedCorrectedTokenIsNeverCorrectedAgain() throws {
        let again = try Typo.typed("androdi ⌫ ")  // S73
        #expect(again.field.string == "android ")
        #expect(again.lastDecision == .corrected(.unchanged))
        #expect(again.outputs.last?.action == .passThrough)
        let restored = try Typo.typed("androdi ⌫⎋ ")
        #expect(restored.field.string == "androdi ")
        #expect(restored.lastDecision == .kept(.userChoice))
        #expect(restored.learningSignals == [.neverCorrect(raw: "androdi")])
        // A token undone after its commit, re-opened and committed again, stays the user's choice too.
        let undone = try Typo.typed("androdi ⎋⌫ ")
        #expect(undone.field.string == "androdi ")
        #expect(undone.lastDecision == .kept(.userChoice))
        #expect(undone.learningSignals == [.neverCorrect(raw: "androdi")])
        // A toggle right after the re-commit undoes the correction it still shows.
        let late = try Typo.typed("androdi ⌫ ⎋")
        #expect(late.field.string == "androdi ")
        #expect(late.learningSignals == [.neverCorrect(raw: "androdi")])
    }

    @Test func keysTypedIntoAReopenedCorrectionAreAppendedAsTyped() throws {
        var driver = try Typo.typed("androdi ⌫s")
        #expect(driver.field.string == "androids")
        #expect(driver.state.isLiteral && driver.state.activeRawKeys == "androdis")
        try driver.type(" ")
        #expect(driver.field.string == "androids ")
        #expect(driver.lastDecision == .corrected(.unchanged))
        // The toggle then brings back every key typed; the signal names the word that was corrected.
        let undone = try Typo.typed("androdi ⌫s⎋")
        #expect(undone.field.string == "androdis")
        #expect(undone.learningSignals == [.neverCorrect(raw: "androdi")])
    }

    /// One toggle, one signal (ENG-R861): undoing the cluster case teaches the never-correct list only, and the
    /// re-commit of the restored keys sends no keep-as-typed signal although the rules alone would keep `grẩm`.
    @Test func undoingTheClusterCaseSendsOneSignal() throws {
        let driver = try Typo.typed("gramar ⎋⌫ ")
        #expect(driver.field.string == "gramar ")
        #expect(driver.learningSignals == [.neverCorrect(raw: "gramar")])
        let sentence = try Typo.typed("Whcih ⎋")
        #expect(sentence.field.string == Typo.underQ10(corrected: "Whcih ", typed: "Whcih "))
        #expect(
            sentence.learningSignals
                == (CorrectionPolicy.sentenceStart == .corrected ? [.neverCorrect(raw: "whcih")] : []))
    }

    @Test func withTheSwitchOffNothingChanges_ENGR1119() throws {
        let driver = try Typo.typed("androdi ⎋", typoCorrection: false)  // S66
        #expect(driver.field.string == "androdi ")
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.learningSignals.isEmpty)
        for output in driver.outputs {
            if case .corrected? = output.decision { Issue.record("corrected with the switch off") }
        }
    }

    @Test func theUserListsAndTheNeverCorrectListStopTheCorrection() throws {
        #expect(
            try Typo.field("androdi ", resources: SpecFixtures.correctionResources(userNeverCorrect: ["androdi"]))
                == "androdi ")  // S45
        #expect(
            try Typo.field("androdi ", resources: SpecFixtures.correctionResources(userKeepRaw: ["androdi"]))
                == "androdi ")  // S46
        // S72: the host adds the signal's word to the never-correct list at once (ENG-R1118).
        let first = try Typo.typed("androdi ⎋")
        guard case .neverCorrect(let word)? = first.learningSignals.last else {
            Issue.record("no signal")
            return
        }
        let resources = SpecFixtures.correctionResources(userNeverCorrect: [word])
        var second = EngineDriver(configuration: Typo.configuration(), resources: resources)
        try second.type("androdi ")
        #expect(first.field.string + second.field.string == "androdi androdi ")
        #expect(second.lastDecision == .kept(.unchanged))
    }
}
