// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The revision of the previous token (ENG-R824, ENG-R828), its preconditions and its undo (ENG-R829), with
/// the collision fixture.
@Suite("Revision of the previous token (ENG-R828, ENG-R829)")
struct RevisionTests {
    typealias F = CollisionFixture

    @Test("ENG-R828 RV1: the previous token and this one continue a phrase")
    func phraseLookingForward() throws {
        let driver = try F.driver("dduwowcj as hell ")
        #expect(driver.field.string == "được as hell ")
        #expect(F.revisions(driver) == [.phrase])
        // ENG-R803: one edit covers the previous token, the space and the current token; the space follows.
        guard case .edit(let edit, true)? = driver.outputs.last?.action else {
            Issue.record("the revising commit is not an edit with pass-through")
            return
        }
        #expect(edit.deleteCount == "á hell".count && edit.insert == "as hell")
        // Up to two tokens before: `as soon` revises the first `as`.
        #expect(try F.field("dduwowcj as soon ") == "được as soon ")
    }

    @Test("ENG-R828 RV2: a restored `as` followed by a tail particle becomes á")
    func particleTail() throws {
        let driver = try F.driver("tricky as nha ")
        #expect(driver.field.string == "tricky á nha ")
        #expect(F.revisions(driver) == [.particleTail])
        // Not a particle of the tail list: `rồi` is a tail word, RV2 needs a particle.
        #expect(try F.field("tricky as rooif ") == "tricky as rồi ")
    }

    @Test("ENG-R828 RV3: an English function word after a kept non-particle collision")
    func nextEnglish() throws {
        let driver = try F.driver("if you ")
        #expect(driver.field.string == "if you ")
        #expect(F.revisions(driver) == [.nextEnglish])
        // A particle reading is never restored this way (`Ngon á but mắc`, `Nó đẹp á and rẻ`).
        #expect(try F.field("dduwowcj as and ") == "được á and ")
        // `it`, an all-caps word and a word that is a valid Vietnamese syllable are not evidence.
        #expect(try F.field("if it ") == "ì it ")
        #expect(try F.field("dduwowcj car YOU ") == "được cả YOU ")
        #expect(try F.field("dduwowcj car the ") == "được cả the ")
        // A token restored by an `en` row is not strict English evidence (`is`).
        #expect(try F.field("dduwowcj car is ") == "được cả is ")
    }

    @Test("ENG-R828 RV4: Vietnamese after a function word restored by the English run")
    func nextVietnamese() throws {
        let driver = try F.driver("great job car nhoms ")
        #expect(driver.field.string == "great job cả nhóm ")
        #expect(F.revisions(driver) == [.nextVietnamese])
        // Tail word: `the car rồi`, `theme quá` keep the English word.
        #expect(try F.field("great job car quas ") == "great job car quá ")
        // Pre-guard: `you been ở` stays English.
        #expect(try F.field("have you been owr ") == "have you been ở ")
        // A content word on neither list is not revised.
        #expect(try F.field("great job test nhoms ") == "great job test nhóm ")
        // An unchanged Tier A syllable of two letters or more whose keys are not English is evidence.
        #expect(try F.field("great job car nha ") == "great job car nha ")
        #expect(try F.field("great job car toi ") == "great job cả toi ")
        #expect(try F.field("great job car TOI ") == "great job car TOI ")
    }

    @Test("ENG-R828: a pre-guard word that shows a Vietnamese collision display does not guard")
    func preGuardShowingVietnamese() throws {
        // `has` restored by the English run guards `car`.
        #expect(try F.field("great has car nhoms ") == "great has car nhóm ")
        // Kept `há` by the memory (neutral, so `car` is still in an English run), it is Vietnamese on screen
        // and does not guard: RV4 revises `car`.
        let memory = F.resources(
            memory: CollisionMemorySnapshot([.init(word: "has", context: nil, choice: .vietnamese)]))
        #expect(try F.field("great has car nhoms ", resources: memory) == "great há cả nhóm ")
    }

    @Test("ENG-R828 preconditions: one space, nothing between the two commits, the switch on")
    func preconditions() throws {
        #expect(try F.field("dduwowcj as  hell ") == "được á  hell ")
        #expect(try F.field("dduwowcj as, hell ") == "được á, hell ")
        #expect(try F.field("dduwowcj as \u{27F2}hell ") == "được á hell ")
        #expect(try F.field("dduwowcj as \u{238B}hell ") == "được á hell ")
        // A Backspace into the history (here over a second space) ends the chance.
        #expect(try F.field("dduwowcj as  \u{232B}hell ") == "được á hell ")
        // A Backspace inside the next token does not.
        #expect(try F.field("dduwowcj as hellx\u{232B} ") == "được as hell ")
        // The previous token chosen by the user (L1) is never revised.
        #expect(try F.field("dduwowcj as\u{238B}\u{232B}s\u{238B} hell ") == "được á hell ")
        let off = EngineConfiguration(lookaheadRevision: false)
        #expect(try F.field("dduwowcj as hell ", configuration: off) == "được á hell ")
        let manual = EngineConfiguration(autoRestore: false)
        #expect(try F.field("dduwowcj as hell ", configuration: manual) == "được á hell ")
        #expect(try F.field("tricky as nha ", configuration: manual) == "tricky á nha ")
    }

    @Test("ENG-R828: a macro expansion is not a commit that revises")
    func macroDoesNotRevise() throws {
        var resources = F.resources()
        resources.macros = try MacroTable([.init(trigger: "hell", expansion: "heaven")])
        #expect(try F.field("dduwowcj as hell ", resources: resources) == "được á heaven ")
        // and the macro token is not revised by the next commit
        #expect(try F.field("dduwowcj hell nha ", resources: resources) == "được heaven nha ")
    }

    @Test("ENG-R828 a revision at Return happens before the Return is delivered")
    func revisionAtReturn() throws {
        let driver = try F.driver("dduwowcj as hell\n")
        #expect(driver.field.string == "được as hell\n")
        #expect(F.revisions(driver) == [.phrase])
    }

    @Test("ENG-R823: the revised token's language replaces the one it had")
    func languageAfterRevision() throws {
        let rv1 = try F.driver("dduwowcj as hell ")
        let revised = try #require(rv1.state.history.token(beforeNewest: 3))
        #expect(revised.committedText == "as" && revised.language == .english && revised.collision.revision == .phrase)
        let rv4 = try F.driver("great job car nhoms ")
        let car = try #require(rv4.state.history.token(beforeNewest: 3))
        #expect(car.committedText == "cả" && car.language == .neutral)
        // The window holds the revised language: [job en, car neutral, nhóm vi].
        var window = RecentLanguages()
        for language in [TokenLanguage.english, .neutral, .vietnamese] { window.push(language) }
        #expect(rv4.state.recentLanguages == window)
    }

    @Test("ENG-R1002: a revised token re-opens with its new text, and the toggle composes it again")
    func reopeningARevisedToken() throws {
        // Backspace over `hell ` and the space re-opens `as`, restored by the revision (ENG-R701, ENG-R704).
        let driver = try F.driver("dduwowcj as hell \u{232B}\u{232B}\u{232B}\u{232B}\u{232B}\u{232B}")
        #expect(driver.field.string == "được as" && driver.state.activeRawKeys == "as" && driver.state.isLiteral)
        var toggled = driver
        try toggled.send(.restoreToggle)
        #expect(toggled.field.string == "được á")
        // A token revised to Vietnamese re-opens composed.
        let rv2 = try F.driver("tricky as nha \u{232B}\u{232B}\u{232B}\u{232B}\u{232B}")
        #expect(rv2.field.string == "tricky á" && !rv2.state.isLiteral)
    }

    @Test("ENG-R829: the toggle right after a revising commit undoes the revision")
    func undo() throws {
        var driver = try F.driver("dduwowcj as hell ")
        let output = try driver.send(.restoreToggle)
        #expect(driver.field.string == "được á hell ")
        guard case .edit(_, false) = output.action else {
            Issue.record("the undo is not an edit that consumes the key")
            return
        }
        #expect(
            output.collisionSignals == [
                CollisionSignal(word: "as", context: .afterVietnamese, side: .vietnamese, strength: .strong)
            ])
        let undone = try #require(driver.state.history.token(beforeNewest: 3))
        #expect(
            undone.decision == .kept(.userChoice) && undone.collision.revision == nil && undone.language == .vietnamese)
        #expect(driver.state.recentLanguages.isEnglishRun == false)
        // ENG-R702: the next toggle passes through.
        #expect(try driver.send(.restoreToggle).action == .passThrough)
        #expect(driver.field.string == "được á hell ")
        // An undone token is not revised again by the next commit and keeps the user's choice when re-opened.
        try driver.send(KeyNotation.events("nha "))
        #expect(driver.field.string == "được á hell nha ")
    }

    @Test("ENG-R829: undoing RV2 and RV4 restores the English word")
    func undoTowardEnglish() throws {
        var rv2 = try F.driver("tricky as nha ")
        let output = try rv2.send(.restoreToggle)
        #expect(rv2.field.string == "tricky as nha ")
        #expect(output.collisionSignals.map(\.side) == [.english])
        #expect(rv2.state.history.token(beforeNewest: 3)?.decision == .restored(.userChoice))
        var rv4 = try F.driver("great job car nhoms ")
        try rv4.send(.restoreToggle)
        #expect(rv4.field.string == "great job car nhóm ")
    }

    @Test("ENG-R829: no undo after Return, after another event, or when nothing was revised")
    func noUndo() throws {
        var afterReturn = try F.driver("dduwowcj as hell\n")
        #expect(try afterReturn.send(.restoreToggle).action == .passThrough)
        var afterKey = try F.driver("dduwowcj as hell n")
        try afterKey.send(.restoreToggle)
        #expect(afterKey.field.string == "được as hell n")
        var plain = try F.driver("dduwowcj as nha ")
        #expect(try plain.send(.restoreToggle).action == .passThrough)
        // A non-ASCII boundary after the revising commit: the toggle passes through.
        var unicode = try F.driver("dduwowcj as hell\u{2014}")
        #expect(try unicode.send(.restoreToggle).action == .passThrough)
    }

    @Test("ENG-R1202: the engine never changes the memory snapshot it reads")
    func snapshotIsNeverMutated() throws {
        let snapshot = CollisionMemorySnapshot([.init(word: "car", context: nil, choice: .english)])
        let resources = F.resources(memory: snapshot)
        let engine = Engine(configuration: EngineConfiguration(), resources: resources)
        var session = Session(engine: engine)
        for event in KeyNotation.events("car \u{232B}\u{238B} dduwowcj as hell \u{238B}nha\n") {
            _ = session.handle(event)
        }
        #expect(engine.resources.collisionMemory == snapshot)
        #expect(session.engine.resources.collisionMemory == snapshot)
    }
}
