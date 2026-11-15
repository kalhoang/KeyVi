// SPDX-License-Identifier: GPL-3.0-or-later
//
// `inlineCompletion: forwardDelete` (PLT-R423) on `SimulatedTextField`. Retest of beta 2 (15/11/2026): in Spotlight on
// macOS 27.2 `tiee` gave "tieê" and `tieesng` "tieếng"; the field shows its suggestion after the caret without
// selecting it, a Backspace removes only that suggestion and a Forward Delete removes it too. The simulated field
// offers the suggestion again after every deletion at the end, the worst case for an edit that deletes twice.

import AppModel
import InputHost
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private struct Bench {
    let layout = InjectionTestLayouts.qwerty()
    let field: SimulatedTextField
    let poster: FakeEventPoster
    let access: FakeFocusedFieldAccess
    let environment: FakeInjectionEnvironment

    init(field: SimulatedTextField, ax: FakeFocusedFieldAccess.Behaviour = .normal) {
        self.field = field
        poster = InjectionFieldWiring.poster(for: field, layout: layout)
        access = FakeFocusedFieldAccess(field: field, behaviour: ax)
        environment = FakeInjectionEnvironment(
            poster: poster, clock: ManualClock(), fieldAccess: access, pasteboard: FakePasteboard())
    }

    func type(_ text: String) {
        for character in text {
            field.apply(InjectionFieldWiring.keyDown(character, receivedAt: Fixture.start), layout: layout)
        }
    }

    @discardableResult
    func run(
        deleteCount: Int, insertion: String, strategy: InjectionStrategy = .backspaceReplace,
        mode: InlineCompletionMode = .forwardDelete, field handle: FieldHandle? = Fixture.field
    ) -> StrategyOutcome {
        let plan = Fixture.plan(strategy, parameters: Fixture.parameters { $0.inlineCompletion = mode })
        let job = Fixture.job(deleteCount: deleteCount, insertion: insertion, plan: plan, field: handle)
        return StrategyCatalog.executor(for: strategy).execute(job, in: environment)
    }

    var keyDownCodes: [KeyCode] { poster.posted.keyDowns.map(\.keyCode) }
    var forwardDeleteCount: Int { keyDownCodes.filter { $0 == .forwardDelete }.count }
}

/// Spotlight on macOS 27.2 as the product owner described it: "tie" shows a suggestion after the caret.
private func spotlight(countedByAX: Bool = false) -> SimulatedTextField {
    SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: ["tieng.example"], countedByAX: countedByAX))
}

@Suite struct ForwardDeleteCompletionTests {
    /// The bug of the retest: without handling, the first Backspace only removes the suggestion.
    @Test func withoutHandlingTheSuggestionAbsorbsTheFirstBackspace() {
        let bench = Bench(field: spotlight())
        bench.type("tie")
        #expect(bench.field.suggestionShown == "ng.example")
        #expect(bench.field.axSelectedRange().length == 0)  // AX reports no selection ("completion none")
        bench.run(deleteCount: 1, insertion: "ê", mode: .axSelection)
        #expect(bench.field.text == "tieê")
    }

    /// PLT-R423: `tiee` gives "tiê", then `n` and `s` (delete 2) give "tiến" and `g` "tiếng".
    @Test func tieesngGivesTiengPLTR423() {
        let bench = Bench(field: spotlight())
        bench.type("tie")
        bench.run(deleteCount: 1, insertion: "ê")
        #expect(bench.field.text == "tiê")
        bench.type("n")
        bench.run(deleteCount: 2, insertion: "ến")
        bench.type("g")
        #expect(bench.field.text == "tiếng")
    }

    /// PLT-R423: one Forward Delete immediately before each Backspace, then the insertion. The field offers the
    /// suggestion again after the first deletion, so a Forward Delete before the first Backspace only would leave
    /// "tiiế".
    @Test func aForwardDeleteGoesBeforeEveryBackspacePLTR423() {
        let bench = Bench(field: spotlight())
        bench.type("tie")
        bench.run(deleteCount: 2, insertion: "iế")
        #expect(bench.field.text == "tiế")
        let trigger = Fixture.triggerS.keyCode
        #expect(bench.keyDownCodes == [.forwardDelete, .delete, .forwardDelete, .delete, trigger, trigger])
        let forwardDeletes = bench.poster.posted.compactMap(\.synthetic).filter { $0.keyCode == .forwardDelete }
        #expect(forwardDeletes.map(\.isKeyDown) == [true, false, true, false])  // keyDown plus keyUp (PLT-R407)
        #expect(forwardDeletes.allSatisfy { $0.flags == 0 && $0.unicode.count == 0 })  // PLT-R405, PLT-R406
    }

    /// At the end of a field without a suggestion a Forward Delete deletes nothing.
    @Test func atTheEndWithoutASuggestionTheEditIsUnchanged() {
        let bench = Bench(field: SimulatedTextField(text: "viet"))
        bench.run(deleteCount: 2, insertion: "ệt")
        #expect(bench.field.text == "việt")
        #expect(bench.forwardDeleteCount == 2)
    }

    /// PLT-R423 keeps PLT-R420 for a selected suggestion (Spotlight before macOS 27.2): one extra Backspace removes the
    /// selection, no Forward Delete.
    @Test func aSelectedSuggestionGetsTheExtraBackspaceAndNoForwardDeletePLTR420() {
        let bench = Bench(field: SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"])))
        bench.type("a")
        #expect(bench.field.selectedText == "mazon")
        bench.run(deleteCount: 1, insertion: "á")
        #expect(bench.field.text == "á")
        #expect(bench.poster.posted.backspaceCount == 2)
        #expect(bench.forwardDeleteCount == 0)
    }

    /// A caret before the end of the text: a Forward Delete there would delete a real character, so none is posted
    /// and the "t" after the caret survives.
    @Test func aCaretBeforeTheEndGetsNoForwardDeletePLTR423() {
        let bench = Bench(field: spotlight())
        bench.type("viet")
        bench.field.click(at: 3)  // between "e" and "t"
        bench.run(deleteCount: 1, insertion: "ê")
        #expect(bench.field.text == "viêt")
        #expect(bench.forwardDeleteCount == 0)
        #expect(bench.poster.posted.backspaceCount == 1)
    }

    /// An unreadable field gets neither a Forward Delete nor an extra Backspace: the old symptom, never lost text.
    @Test(arguments: [FakeFocusedFieldAccess.Behaviour.timeout, .unavailable])
    func anUnreadableFieldGetsNoForwardDeletePLTR423(_ ax: FakeFocusedFieldAccess.Behaviour) {
        let bench = Bench(field: spotlight(), ax: ax)
        bench.type("tie")
        bench.run(deleteCount: 1, insertion: "ê")
        #expect(bench.forwardDeleteCount == 0)
        #expect(bench.poster.posted.backspaceCount == 1)
        #expect(bench.field.text == "tieê")
    }

    @Test func aJobWithoutAFieldGetsNoForwardDelete() {
        let bench = Bench(field: spotlight())
        bench.type("tie")
        bench.run(deleteCount: 1, insertion: "ê", field: nil)
        #expect(bench.forwardDeleteCount == 0)
        #expect(bench.access.callCount == 0)
    }

    /// An insertion replaces a suggestion like typing does: no AX read, no Forward Delete.
    @Test func anInsertionOnlyEditReadsNothing() {
        let bench = Bench(field: spotlight())
        bench.type("ti")
        bench.run(deleteCount: 0, insertion: "ê")
        #expect(bench.access.callCount == 0)
        #expect(bench.forwardDeleteCount == 0)
    }

    /// Residual risk (b): a field that counts its suggestion in AX reads as a caret before the end. The handling then
    /// does nothing; the letter doubles as before and nothing else is deleted.
    @Test func aSuggestionCountedByAXIsSkippedSafelyPLTR423() {
        let bench = Bench(field: spotlight(countedByAX: true))
        bench.type("tie")
        bench.run(deleteCount: 1, insertion: "ê")
        #expect(bench.forwardDeleteCount == 0)
        #expect(bench.field.text == "tieê")
    }

    /// `selectReplace`: one Forward Delete before the first Shift+Left when the caret is at the end.
    @Test func selectReplacePostsOneForwardDeleteFirst() {
        let bench = Bench(field: spotlight())
        bench.type("tie")
        bench.run(deleteCount: 1, insertion: "ê", strategy: .selectReplace)
        #expect(bench.field.text == "tiê")
        #expect(bench.keyDownCodes == [.forwardDelete, .leftArrow, Fixture.triggerS.keyCode])
    }

    /// 1,000 randomised edits at the end of the field: the text is always exactly what was typed.
    @Test func randomisedEditsAtTheEndLeaveExactlyTheTypedText() {
        var generator = SplitMix64(seed: 0x0F0D_E1E7)
        let words = ["tieng.example", "viet.example", "duong.example", "dang.example", "nguyen.example"]
        let field = SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: words))
        let bench = Bench(field: field)
        let letters = Array("adegnhiotuvy")
        for _ in 0..<1_000 {
            field.reset()
            var expected = ""
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let letter = letters[Int.random(in: 0..<letters.count, using: &generator)]
                bench.type(String(letter))
                expected.append(letter)
            }
            let deleteCount = Int.random(in: 1...expected.count, using: &generator)
            let replacement = ["á", "ư", "ộ", "đ", "ể", "ằn"][Int.random(in: 0..<6, using: &generator)]
            bench.run(deleteCount: deleteCount, insertion: replacement)
            expected = String(expected.dropLast(deleteCount)) + replacement
            #expect(field.text == expected)
        }
    }

    /// The product owner's retest item: type a word, move the caret left, type an edit. Nothing to the right of the
    /// caret disappears, whatever the word and the position.
    @Test func randomisedEditsBeforeTheEndKeepTheTextAfterTheCaret() {
        var generator = SplitMix64(seed: 0xCA2E_7000)
        let field = SimulatedTextField(behaviour: .suggestionAfterCaret(suggestions: ["vietnam.example"]))
        let bench = Bench(field: field)
        let letters = Array("adegnhiotuvy")
        for _ in 0..<1_000 {
            let word = String(
                (0..<Int.random(in: 2...6, using: &generator)).map { _ in
                    letters[Int.random(in: 0..<letters.count, using: &generator)]
                })
            field.reset()
            bench.type(word)
            let caret = Int.random(in: 1..<word.count, using: &generator)
            field.click(at: caret)
            let tail = String(word.dropFirst(caret))
            let deleteCount = Int.random(in: 1...caret, using: &generator)
            bench.run(deleteCount: deleteCount, insertion: "ế")
            #expect(field.text == String(word.prefix(caret - deleteCount)) + "ế" + tail)
        }
    }
}
