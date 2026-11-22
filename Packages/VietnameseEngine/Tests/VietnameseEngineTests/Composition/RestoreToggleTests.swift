// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.10: every row E01-E13 and E02b, with the 13.9 fixture resources (E04 needs the commit restore
/// of `test` by rule L11 and the history re-open of section 10; E09 to E13 the English run of rule L10 and the undo
/// of ENG-R706).
@Suite("Restore toggle (7.2, 13.10)")
struct RestoreToggleTests {
    static let allRows: Set<String> = [
        "E01", "E02", "E02b", "E03", "E04", "E05", "E06", "E07", "E08", "E09", "E10", "E11", "E12", "E13",
    ]

    static let rows: [RestoreToggleExample] = {
        do {
            return try SpecExamples.restoreToggles(tsv: CorpusFiles.text(SpecExamples.restoreToggleFile))
        } catch {
            Issue.record("cannot load \(SpecExamples.restoreToggleFile): \(error)")
            return []
        }
    }()

    @Test func rowsArePresent() {
        #expect(Set(Self.rows.map(\.id)) == Self.allRows)
    }

    @Test(arguments: rows)
    func toggle(_ row: RestoreToggleExample) throws {
        var driver = EngineDriver(configuration: row.configuration, resources: SpecFixtures.commitResources())
        try driver.send(row.events)
        #expect(driver.state.activeDisplay == row.expectedActive, "\(row.id): \(row.eventsText)")
        if let field = row.expectedField { #expect(driver.field.string == field, "\(row.id): \(row.eventsText)") }
        let last = try #require(driver.outputs.last)
        switch row.lastAction {
        case .passThrough: #expect(last.action == .passThrough, "\(row.id)")
        case .edit:
            guard case .edit(_, let thenPassThrough) = last.action else {
                Issue.record("\(row.id): expected an edit, got \(last.action)")
                return
            }
            #expect(!thenPassThrough, "\(row.id): the toggle key is swallowed")
        }
    }

    @Test func e04UndoesTheAutomaticRestore() throws {
        // ENG-R704: `test` + space commits `test ` (L11); Backspace re-opens `test` in its restored state;
        // the toggle shows `tét` and marks the token user-kept; the next space keeps it (L1) and emits the
        // learning signal of ENG-R861.
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: SpecFixtures.commitResources())
        try driver.type("test ")
        #expect(driver.field.string == "test " && driver.outputs.last?.decision == .restored(.ambiguityTable))
        try driver.send(.backspace)
        #expect(driver.state.activeDisplay == "test" && driver.state.isLiteral && driver.field.string == "test")
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "tét" && driver.state.active?.userChoice == .kept)
        try driver.type(" ")
        #expect(driver.field.string == "tét ")
        #expect(driver.outputs.last?.decision == .kept(.userChoice))
        #expect(driver.outputs.last?.learning == .preferredVietnamese(raw: "test"))
    }

    @Test func e02bThenCommitKeepsTheUserChoice() throws {
        // E02b continued: the user-kept `việ` commits as the user chose (L1).
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: SpecFixtures.commitResources())
        try driver.type("vieejt")
        try driver.send(.restoreToggle)
        try driver.send(.backspace)
        try driver.send(.restoreToggle)
        try driver.type(".")
        #expect(driver.field.string == "việ.")
        #expect(driver.outputs.last?.decision == .kept(.userChoice))
        // `việ` is not a syllable (open `iê`), so the rules alone would restore it (L5): learning signal.
        #expect(driver.outputs.last?.learning == .preferredVietnamese(raw: "vieej"))
    }

    @Test func restoredTokenIsLiteralForTheRestOfTheToken() throws {
        // ENG-R701: user-restored means literal for the rest of the token.
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.type("vieejt")
        try driver.send(.restoreToggle)
        try driver.type("s")
        #expect(driver.state.activeDisplay == "vieejts")
        #expect(driver.state.isLiteral)
        #expect(driver.outputs.last?.action == .passThrough)
        // Not consecutive: composes again and marks the token user-kept.
        try driver.send(.restoreToggle)
        #expect(driver.state.activeDisplay == "viết")
        try driver.send(.restoreToggle)  // consecutive: passes through, nothing changes (ENG-R702)
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.state.activeDisplay == "viết")
    }

    @Test func tokenRestoredByARuleComposesOnToggle() {
        // ENG-R701 second branch for a token that a commit rule restored and Backspace re-opened
        // (ENG-R704): it shows its raw keys, the toggle brings the composed form back and marks it
        // user-kept.
        let configuration = EngineConfiguration(typoCorrection: false)
        let rules = ComposerRules(configuration)
        let composition = Composition(replaying: Array("test".utf8), rules: rules)
        var token = ActiveToken(composition: composition, display: "test", userChoice: .none, restoredByRule: true)
        #expect(token.showsRawKeys && token.isLiteral)
        #expect(token.composedDisplay(style: .traditional) == "tét")
        let action = token.toggleRestore(rules: rules)
        #expect(action == .edit(TextEdit(deleteCount: 3, deleteUTF16Count: 3, insert: "ét"), thenPassThrough: false))
        #expect(token.display == "tét" && token.userChoice == .kept && !token.showsRawKeys)
        // A user-kept token whose display differs from its raw keys restores again (first branch).
        #expect(token.toggleRestore(rules: rules) != nil)
        #expect(token.display == "test" && token.userChoice == .restored)
    }

    @Test func toggleWithoutTokenPassesThrough() throws {
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.send(.restoreToggle)
        #expect(driver.outputs.last?.action == .passThrough)
        try driver.type("ban ")
        try driver.send(.restoreToggle)
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.field.string == "ban ")
    }

    @Test func vniRestoreReproducesDigits() throws {
        // ENG-R705, REG-05.
        var driver = EngineDriver(configuration: EngineConfiguration(inputMethod: .vni, typoCorrection: false))
        try driver.type("vie65t")
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "vie65t")
        #expect(driver.state.activeRawKeys == "vie65t")
    }
}
