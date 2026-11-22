// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The learning signals for collision words (ENG-R864, ENG-R866) and the context classes of the memory
/// (ENG-R863), with the collision fixture.
@Suite("Collision signals (ENG-R864)")
struct CollisionSignalTests {
    typealias F = CollisionFixture

    private func weak(_ word: String, _ context: CollisionContext, _ side: Language) -> CollisionSignal {
        CollisionSignal(word: word, context: context, side: side, strength: .weak)
    }

    private func strong(_ word: String, _ context: CollisionContext, _ side: Language) -> CollisionSignal {
        CollisionSignal(word: word, context: context, side: side, strength: .strong)
    }

    @Test("ENG-R864: a decision becomes a weak signal after three later commits")
    func weakAfterThreeCommits() throws {
        let driver = try F.driver("dduwowcj car a b c ")
        let commits = driver.outputs.filter { $0.decision != nil }
        #expect(commits.map(\.collisionSignals.count) == [0, 0, 0, 0, 1])
        #expect(commits.last?.collisionSignals == [weak("car", .afterVietnamese, .vietnamese)])
        // Restored by the English run: the English side.
        #expect(F.signals(try F.driver("tricky car a b c ")) == [weak("car", .afterEnglish, .english)])
    }

    @Test("ENG-R864: Return and Tab make every pending decision final")
    func weakAtReturn() throws {
        for boundary in ["\n", "\t"] {
            let driver = try F.driver("car this" + boundary)
            #expect(
                driver.outputs.last?.collisionSignals == [
                    weak("car", .sentenceStart, .vietnamese), weak("this", .afterNeutral, .vietnamese),
                ])
        }
        // A Return with no active token flushes too.
        #expect(try F.driver("car \n").outputs.last?.collisionSignals == [weak("car", .sentenceStart, .vietnamese)])
    }

    @Test("ENG-R864: no weak signal for L9a, L9b, revised tokens, words off the list, or after a reset")
    func noWeakSignal() throws {
        #expect(F.signals(try F.driver("tricky as.\n")).isEmpty)
        #expect(F.signals(try F.driver("dduwowcj has been\n")).isEmpty)
        #expect(F.signals(try F.driver("dduwowcj as hell\n")).isEmpty)
        #expect(F.signals(try F.driver("vieejt dduwowcj a b c\n")).isEmpty)
        #expect(F.signals(try F.driver("car a \u{27F2}b c d\n")).isEmpty)
    }

    @Test("ENG-R864: the collision supplement gives weak signals through L7")
    func supplementSignal() throws {
        #expect(F.signals(try F.driver("cos\n")) == [weak("cos", .sentenceStart, .vietnamese)])
    }

    @Test("ENG-R864: re-opening a token withdraws its signal until its next commit")
    func reopenWithdraws() throws {
        let driver = try F.driver("car \u{232B} a b c d\n")
        #expect(F.signals(driver) == [weak("car", .sentenceStart, .vietnamese)])
        // A macro that folds the token withdraws it too.
        var resources = F.resources()
        resources.macros = try MacroTable([.init(trigger: "car.b", expansion: "X")])
        #expect(F.signals(try F.driver("car.b c d e\n", resources: resources)).isEmpty)
    }

    @Test("ENG-R864: the toggle against the rules gives a strong signal at commit, after Backspace too")
    func strongSignals() throws {
        // ENG-R704: re-open `test`, toggle, commit: the user keeps `tét` against the `en` row.
        let reopened = try F.driver("test \u{232B}\u{238B} ")
        #expect(reopened.outputs.last?.collisionSignals == [strong("test", .sentenceStart, .vietnamese)])
        #expect(reopened.outputs.last?.learning == .preferredVietnamese(raw: "test"))
        let restored = try F.driver("dduwowcj car\u{238B} ")
        #expect(restored.outputs.last?.collisionSignals == [strong("car", .afterVietnamese, .english)])
        // A toggle the rules agree with, and a word off the list, give no collision signal.
        #expect(F.signals(try F.driver("test\u{238B} ")).isEmpty)
        #expect(F.signals(try F.driver("vieejt\u{238B} ")).isEmpty)
    }

    @Test("ENG-R861, ENG-R864: one toggle gives one signal, however often the token is re-committed")
    func oneSignalPerToggle() throws {
        // Toggle, space, Backspace (re-opens the token), space: the second commit repeats the same choice.
        let driver = try F.driver("dduwowcj car\u{238B} \u{232B} ")
        #expect(driver.field.string == "được car ")
        #expect(F.signals(driver) == [strong("car", .afterVietnamese, .english)])
        #expect(driver.outputs.compactMap(\.learning) == [.preferredRaw(raw: "car")])
        // A new toggle on the re-opened token is a new choice and gives its own signal.
        let again = try F.driver("test \u{232B}\u{238B} \u{232B}\u{238B} ")
        #expect(again.field.string == "test ")
        #expect(F.signals(again) == [strong("test", .sentenceStart, .vietnamese)])
        let toggledTwice = try F.driver("dduwowcj car\u{238B} \u{232B}\u{238B} \u{232B}\u{238B} ")
        #expect(toggledTwice.field.string == "được car ")
        #expect(
            F.signals(toggledTwice) == [
                strong("car", .afterVietnamese, .english), strong("car", .afterVietnamese, .english),
            ])
    }

    @Test("ENG-R864: correcting a revision after Backspace re-opened the word is a strong signal")
    func correctingARevisionAfterBackspace() throws {
        // RV1 restored `as`; six Backspaces re-open it; the toggle brings `á` back against the revision.
        let restored = try F.driver("dduwowcj as hell " + String(repeating: "\u{232B}", count: 6) + "\u{238B} ")
        #expect(restored.field.string == "được á ")
        #expect(F.signals(restored) == [strong("as", .afterVietnamese, .vietnamese)])
        #expect(restored.outputs.last?.learning == .preferredVietnamese(raw: "as"))
        // RV4 made `car` Vietnamese; re-opened and toggled, it goes back to English.
        let kept = try F.driver("great job car nhoms " + String(repeating: "\u{232B}", count: 6) + "\u{238B} ")
        #expect(kept.field.string == "great job car ")
        #expect(F.signals(kept) == [strong("car", .afterEnglish, .english)])
        // A letter deleted and typed again leaves the raw keys RV1 decided: the revision still stands for the
        // rules, so restoring `as` agrees with it and reports nothing.
        let retyped = try F.driver("dduwowcj as hell " + String(repeating: "\u{232B}", count: 7) + "s\u{238B} ")
        #expect(retyped.field.string == "được as ")
        #expect(F.signals(retyped).isEmpty)
        #expect(retyped.outputs.compactMap(\.learning).isEmpty)
    }

    @Test("ENG-R864: raw keys edited inside a re-opened revised word drop the revision's side")
    func editingARevisedWordDropsTheRevision() throws {
        // RV3 restored `been`; the toggle after a Backspace shows `bê`, which the rules alone give for `bee`,
        // so it corrects nothing.
        let backspaced = try F.driver("dduwowcj been you " + String(repeating: "\u{232B}", count: 6) + "\u{238B} ")
        #expect(backspaced.field.string == "được bê ")
        #expect(backspaced.outputs.compactMap(\.learning).isEmpty)
        // The same after a key typed into it (`beenh`, `bênh`).
        let typed = try F.driver("dduwowcj been you " + String(repeating: "\u{232B}", count: 5) + "h\u{238B} ")
        #expect(typed.field.string == "được bênh ")
        #expect(typed.outputs.compactMap(\.learning).isEmpty)
        // A letter deleted and typed again leaves the raw keys the revision decided: the toggle against RV3
        // still counts as a correction.
        let same = try F.driver("dduwowcj been you " + String(repeating: "\u{232B}", count: 5) + "\u{238B}\u{232B}n ")
        #expect(same.field.string == "được bên ")
        #expect(same.outputs.compactMap(\.learning) == [.preferredVietnamese(raw: "been")])
    }

    @Test("ENG-R861, ENG-R864: the toggle that undoes a revision reports the choice once")
    func undoReportsOnce() throws {
        // RV1 restored `as`; the toggle undoes it (`á`) with a strong signal; re-opened and committed again with
        // the same choice, `as` reports nothing new.
        let driver = try F.driver("tricky as nha \u{238B}" + String(repeating: "\u{232B}", count: 5) + ".")
        #expect(driver.field.string == "tricky as.")
        #expect(F.signals(driver) == [strong("as", .afterEnglish, .english)])
        #expect(driver.outputs.compactMap(\.learning).isEmpty)
    }

    @Test("ENG-R861: a re-opened token edited into other raw keys reports its own choice")
    func editedTokenReportsItsOwnChoice() throws {
        // `car` restored by the toggle, re-opened and edited to `cas`: a choice for `cas` never reported.
        let edited = try F.driver("dduwowcj car\u{238B} \u{232B}\u{232B}s ")
        #expect(edited.field.string == "được cas ")
        #expect(edited.outputs.compactMap(\.learning) == [.preferredRaw(raw: "car"), .preferredRaw(raw: "cas")])
        // The same letters deleted and typed again are the same choice: no second signal.
        let retyped = try F.driver("dduwowcj car\u{238B} \u{232B}\u{232B}r ")
        #expect(retyped.field.string == "được car ")
        #expect(retyped.outputs.compactMap(\.learning) == [.preferredRaw(raw: "car")])
        #expect(F.signals(retyped) == [strong("car", .afterVietnamese, .english)])
    }

    @Test("ENG-R866: a signal carries the bundled list's word in lowercase, whatever the case typed")
    func signalWordIsTheListWord() throws {
        let driver = try F.driver("CAR\n")
        #expect(F.signals(driver) == [weak("car", .sentenceStart, .vietnamese)])
    }

    @Test("ENG-R863: the context class of the previous token")
    func contextClasses() throws {
        func context(_ keys: String) throws -> CollisionContext? { F.signals(try F.driver(keys + "\n")).last?.context }
        #expect(try context("car") == .sentenceStart)
        #expect(try context("dduwowcj. car") == .sentenceStart)
        #expect(try context("dduwowcj: car") == .sentenceStart)
        #expect(try context("dduwowcj, car") == .afterVietnamese)
        #expect(try context("and car") == .afterEnglish)
        #expect(try context("a car") == .afterNeutral)
        // The English-lean window counts (`the` is English, ENG-R823).
        #expect(try context("the tows") == .afterEnglish)
    }

    @Test("ENG-R864: signals do not depend on lookaheadRevision")
    func signalsWithoutTheContextRules() throws {
        let off = EngineConfiguration(lookaheadRevision: false, typoCorrection: false)
        #expect(F.signals(try F.driver("car\n", configuration: off)) == [weak("car", .sentenceStart, .vietnamese)])
        #expect(F.revisions(try F.driver("dduwowcj as hell\n", configuration: off)).isEmpty)
    }
}
