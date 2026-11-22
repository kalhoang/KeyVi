// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R706 (REG-42, the product owner's report of 23/11/2026): the restore toggle right after a commit that restored
/// its token because of the tokens before it (rule L10, the English run, and rule L9b, a phrase) puts the composed form
/// back, when the token alone would have kept it (rule L11). It mirrors the revision undo of ENG-R829. Collision
/// fixture: `tricky` is English, `as` and `been` are `vi` rows, `best` is an `en` row, `has been` and `such as` are
/// phrases.
@Suite("Undo of a context restore (ENG-R706, REG-42)")
struct ContextRestoreUndoTests {
    typealias F = CollisionFixture

    @Test("ENG-R706: the toggle right after an English-run restore puts the composed form back")
    func undoesTheEnglishRunRestore() throws {
        var driver = try F.driver("tricky as ")
        #expect(driver.field.string == "tricky as " && driver.outputs.last?.decision == .restored(.englishRun))
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "tricky á ")
        // One edit over the restored keys and the boundary character, the key consumed (the shape of ENG-R829).
        guard case .edit(let edit, false) = output.action else {
            Issue.record("the undo is not an edit that consumes the key")
            return
        }
        #expect(edit.deleteCount == "as ".count && edit.deleteUTF16Count == "as ".utf16.count && edit.insert == "á ")
        #expect(output.decision == nil && output.revision == nil && output.composingText.isEmpty)
        // The learning of the Backspace-then-toggle path (ENG-R704, ENG-R861) and the strong signal of ENG-R864.
        #expect(output.learning == .preferredVietnamese(raw: "as"))
        #expect(
            output.collisionSignals == [
                CollisionSignal(word: "as", context: .afterEnglish, side: .vietnamese, strength: .strong)
            ])
        let undone = try #require(driver.state.history.token(beforeNewest: 1))
        #expect(undone.decision == .kept(.userChoice) && undone.committedText == "á")
        #expect(undone.language == .vietnamese && undone.token.userChoice == .kept)
        #expect(driver.state.recentLanguages.isEnglishRun == false)
        // ENG-R702: the next toggle passes through and changes nothing.
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        #expect(driver.field.string == "tricky á ")
    }

    @Test("ENG-R706: the toggle right after a phrase restore puts the composed form back")
    func undoesThePhraseRestore() throws {
        var driver = try F.driver("such as ")
        #expect(driver.field.string == "such as " && driver.outputs.last?.decision == .restored(.phrase))
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "such á ")
        #expect(output.learning == .preferredVietnamese(raw: "as"))
        #expect(output.collisionSignals.map(\.side) == [.vietnamese])
        #expect(output.collisionSignals.map(\.strength) == [.strong])
    }

    @Test("ENG-R706: the boundary character stays as it was, any ASCII one")
    func keepsTheBoundaryCharacter() throws {
        // `.` and `?` keep `á` by rule L9a (`as` is a boundary particle, ENG-R825): nothing to undo there.
        #expect(try F.field("tricky as.") == "tricky á." && F.field("tricky as?") == "tricky á?")
        let rows = [("tricky as,", "tricky á,"), ("tricky as;", "tricky á;"), ("tricky as)", "tricky á)")]
        for (keys, expected) in rows {
            var driver = try F.driver(keys)
            let output = try driver.send(.restoreToggle)
            #expect(driver.field.string == expected, "\(keys)")
            guard case .edit(let edit, false) = output.action else {
                Issue.record("\(keys): no undo")
                continue
            }
            #expect(edit.deleteCount == 3, "\(keys)")
        }
    }

    @Test("ENG-R706: a restore that the token alone decides is not undone")
    func leavesRestoresTheTokenAloneDecides() throws {
        // `best` is an `en` row: rule L10 restored it first, but rule L11 would have restored it alone.
        var enRow = try F.driver("tricky best ")
        #expect(enRow.field.string == "tricky best " && enRow.outputs.last?.decision == .restored(.englishRun))
        #expect(try enRow.send(.restoreToggle).action == .passThrough)
        #expect(enRow.field.string == "tricky best ")
        // Rules that read the token alone (L5, L11 `en` row) restore it from an empty field too.
        for keys in ["tricky tiesng ", "best ", "tricky test "] {
            var driver = try F.driver(keys)
            #expect(try driver.send(.restoreToggle).action == .passThrough, "\(keys)")
            #expect(driver.field.string == keys, "\(keys)")
        }
        // A kept token and a token typed unchanged: nothing to undo (ENG-R703).
        for keys in ["as ", "tricky hell "] {
            var driver = try F.driver(keys)
            #expect(try driver.send(.restoreToggle).action == .passThrough, "\(keys)")
        }
    }

    @Test("ENG-R706, ENG-R829: no undo after Return or Tab, after a non-ASCII boundary or after another event")
    func mirrorsTheRevisionUndo() throws {
        for keys in ["tricky as\n", "tricky as\t", "tricky as\u{201D}", "tricky as\u{2026}", "tricky as\u{00A0}"] {
            var driver = try F.driver(keys)
            let field = driver.field.string
            let output = try driver.send(.restoreToggle)
            #expect(output.action == .passThrough && output.learning == nil, "\(keys.debugDescription)")
            #expect(output.collisionSignals.isEmpty && driver.field.string == field, "\(keys.debugDescription)")
        }
        // Another event in between: a key starts the next token, a second boundary character, a Backspace.
        var afterKey = try F.driver("tricky as n")
        try afterKey.send(.restoreToggle)
        #expect(afterKey.field.string == "tricky as n")
        var afterSpace = try F.driver("tricky as  ")
        #expect(try afterSpace.send(.restoreToggle).action == .passThrough)
        // Backspace re-opens the token: the toggle of ENG-R704 composes it, as before.
        var afterBackspace = try F.driver("tricky as ⌫")
        try afterBackspace.send(.restoreToggle)
        #expect(afterBackspace.field.string == "tricky á" && afterBackspace.state.active?.userChoice == .kept)
    }

    @Test("ENG-R706, ENG-R829: when the commit also revised the previous token, the toggle undoes the revision")
    func theRevisionUndoComesFirst() throws {
        // `been` continues the phrase `has been` (L9b) and RV1 revises `has`: one commit, two changes.
        var driver = try F.driver("has been ")
        #expect(driver.field.string == "has been " && F.revisions(driver) == [.phrase])
        #expect(driver.outputs.last?.decision == .restored(.phrase))
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "há been ")
        #expect(
            output.collisionSignals == [
                CollisionSignal(word: "has", context: .sentenceStart, side: .vietnamese, strength: .strong)
            ])
        #expect(output.learning == nil)
        // ENG-R702: one toggle, one decision; the second passes through.
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        #expect(driver.field.string == "há been ")
        // The token keeps its own undo: Backspace re-opens it and the toggle composes it (ENG-R704).
        try driver.send(KeyNotation.events("⌫⎋ "))
        #expect(driver.field.string == "há bên ")
        #expect(driver.outputs.last?.learning == .preferredVietnamese(raw: "been"))
    }

    @Test("ENG-R706: the undone token is the user's choice when it is re-opened")
    func theUndoneTokenIsTheUsersChoice() throws {
        // Re-committed unchanged: kept by rule L1, and the choice is reported once (ENG-R861, ENG-R864).
        let driver = try F.driver("tricky as ⎋⌫ ")
        #expect(driver.field.string == "tricky á ")
        let recommit = try #require(driver.outputs.last)
        #expect(recommit.decision == .kept(.userChoice) && recommit.learning == nil)
        #expect(recommit.collisionSignals.isEmpty)
        // The toggle on the re-opened token shows the raw keys again (ENG-R701 first branch, rule L1).
        let again = try F.driver("tricky as ⎋⌫⎋ ")
        #expect(again.field.string == "tricky as " && again.outputs.last?.decision == .restored(.userChoice))
    }

    @Test("ENG-R706, ENG-R823: the undone token is Vietnamese evidence for the next words")
    func theUndoneTokenEndsTheEnglishRun() throws {
        #expect(try F.field("tricky as car ") == "tricky as car ")
        #expect(try F.field("tricky as ⎋car ") == "tricky á cả ")
        // An undone token is not revised by the next commit (the toggle ends the chance, ENG-R828).
        let driver = try F.driver("tricky as ⎋hell ")
        #expect(driver.field.string == "tricky á hell " && F.revisions(driver).isEmpty)
    }

    @Test("ENG-R706, ENG-R864: the weak signal of the restore is withdrawn")
    func withdrawsTheWeakSignal() throws {
        let kept = try F.driver("tricky as \n")
        #expect(
            F.signals(kept) == [CollisionSignal(word: "as", context: .afterEnglish, side: .english, strength: .weak)])
        let undone = try F.driver("tricky as ⎋\n")
        #expect(F.signals(undone).filter { $0.strength == .weak }.isEmpty)
    }

    @Test("ENG-R706: a re-opened token that the English run restores again is undone the same way")
    func reopenedAndCommittedAgain() throws {
        var driver = try F.driver("tricky as ⌫ ")
        #expect(driver.field.string == "tricky as " && driver.outputs.last?.decision == .restored(.englishRun))
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "tricky á ")
    }

    @Test("ENG-R706: auto restore off restores nothing to undo; the other switches leave the undo as it is")
    func configuration() throws {
        let off = EngineConfiguration(autoRestore: false, typoCorrection: false)
        var noRestore = try F.driver("tricky as ", configuration: off)
        #expect(noRestore.field.string == "tricky á " && noRestore.outputs.last?.decision == .kept(.englishRun))
        #expect(try noRestore.send(.restoreToggle).action == .passThrough)
        let others = [
            EngineConfiguration(lookaheadRevision: false, typoCorrection: false),
            EngineConfiguration(typoCorrection: true),
            EngineConfiguration(appContext: .code, typoCorrection: false),
        ]
        for configuration in others {
            var driver = try F.driver("tricky as ", configuration: configuration)
            try driver.send(.restoreToggle)
            #expect(driver.field.string == "tricky á ", "\(configuration)")
        }
    }
}
