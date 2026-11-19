// SPDX-License-Identifier: MPL-2.0
//
// The product owner's retest of 15/11/2026 with the bundled data. Item 21: Escape right after a revision undoes it
// (ENG-R829), but `tricky as hell` from an empty field has no revision: `as` is restored at its own commit because
// the window holds an English token and no Vietnamese one (ENG-R823), so the toggle after it has nothing to undo
// and passes through (ENG-R703). The D29 example of PRD-R79 therefore puts a Vietnamese phrase first. Item 28: the
// learned-words sheet needs a word that defaults to English and whose Vietnamese reading has an `oe` nucleus, so
// the two tone placements (D2) differ; `toes` defaults to Vietnamese (`tóe`), `nose` to English.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("Retest of 15/11/2026 with the bundled data")
struct RetestBeta2RealDataTests {
    static func driver(toneStyle: ToneStyle = .traditional) throws -> EngineDriver {
        EngineDriver(
            configuration: EngineConfiguration(toneStyle: toneStyle, typoCorrection: false),
            resources: try RealData.resources())
    }

    @Test("Item 21, PRD-R79: after a Vietnamese phrase, hell revises á back to as and the toggle undoes it")
    func revisionAfterAVietnamesePhraseIsUndoneByTheToggle() throws {
        var driver = try Self.driver()
        try driver.type("cais nayf tricky as hell ")
        #expect(driver.field.string == "cái này tricky as hell ")
        #expect(driver.outputs.last?.revision != nil)
        let undo = try driver.send(.restoreToggle)
        guard case .edit = undo.action else {
            Issue.record("the toggle consumes the key with an edit (ENG-R829)")
            return
        }
        #expect(driver.field.string == "cái này tricky á hell ")
        #expect(!undo.collisionSignals.isEmpty)  // ENG-R864: a correction against the rules teaches
        try driver.type("nha ")
        #expect(driver.field.string == "cái này tricky á hell nha ")
    }

    @Test("Item 21, ENG-R823: from an empty field tricky as hell has no revision, so the toggle passes through")
    func noRevisionFromAnEmptyField() throws {
        var driver = try Self.driver()
        try driver.type("tricky as hell ")
        #expect(driver.field.string == "tricky as hell ")
        #expect(driver.outputs.allSatisfy { $0.revision == nil })
        let toggle = try driver.send(.restoreToggle)
        #expect(toggle.action == .passThrough)
        #expect(driver.field.string == "tricky as hell ")
    }

    @Test("Item 21, ENG-R828: a Vietnamese word after as revises it to á, and the toggle puts as back")
    func revisionTowardsVietnameseIsUndoneByTheToggle() throws {
        var driver = try Self.driver()
        try driver.type("tricky as nha ")
        #expect(driver.field.string == "tricky á nha ")
        #expect(driver.outputs.last?.revision != nil)
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "tricky as nha ")
    }

    @Test("Item 28, D2: nose stays English by default; its Vietnamese reading follows the tone placement")
    func noseDefaultsToEnglishAndItsReadingFollowsTheTonePlacement() throws {
        for (style, reading) in [(ToneStyle.traditional, "nóe"), (.modern, "noé")] {
            var driver = try Self.driver(toneStyle: style)
            try driver.type("nose ")
            #expect(driver.field.string == "nose ", "\(style)")
            // The correction of the retest: Backspace re-opens the word (ENG-R1002), Escape shows the Vietnamese
            // side (ENG-R701), Space commits it.
            try driver.type("⌫")
            try driver.send(.restoreToggle)
            try driver.type(" ")
            #expect(driver.field.string == reading + " ", "\(style)")
        }
    }

    @Test("Item 28: toes defaults to Vietnamese, which is why the old test step could not teach it")
    func toesDefaultsToVietnamese() throws {
        var driver = try Self.driver(toneStyle: .modern)
        try driver.type("toes ")
        #expect(driver.field.string == "toé ")
    }
}
