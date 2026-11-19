// SPDX-License-Identifier: MPL-2.0
//
// ENG-R1005 with the bundled data (product owner, 15/11/2026, REG-33): a re-opened token that a commit rule
// restored composes again once the remaining raw keys compose to the text shown. The rows need the English
// lexicon (`server`, `Safari`, camel case `useState`, `Tox`); the fixture rows are in ReopenedRestoredTokenTests.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("Re-opened restored token with the bundled data (ENG-R1005)")
struct ReopenedRestoredRealDataTests {
    private static func text(_ keys: String) throws -> String {
        var driver = EngineDriver(
            configuration: EngineConfiguration(typoCorrection: false), resources: try RealData.resources())
        try driver.send(KeyNotation.events(keys))
        return driver.field.string
    }

    @Test(arguments: [
        // The product owner's traces.
        ("tiesng ⌫⌫⌫⌫⌫eesn", "tiến"), ("baas ⌫⌫⌫⌫aasm ", "bấm "), ("huux ⌫⌫wx ", "hữu "),
        // English words restored by the lexicon compose again once deleted back to keys that do not transform.
        ("test ⌫⌫⌫s", "té"), ("tricky as ⌫⌫s", "tricky á"),
    ])
    func retypingComposes(keys: String, expected: String) throws {
        #expect(try Self.text(keys) == expected, "\(keys)")
    }

    /// Rows that ENG-R1005 does not change: keys typed into a word that is still restored stay as typed,
    /// and a commit decides on the raw keys at that moment.
    @Test(arguments: [
        ("text ⌫", "text"), ("Safar ⌫i ", "Safari "), ("server ⌫⌫⌫⌫⌫nd ", "send "), ("boss ⌫⌫", "bos"),
        ("boss ⌫⌫ ", "bó "), ("tieesngg ⌫⌫ ", "tiếng "), ("Tox ⌫⌫x ", "Tox "), ("useState ⌫⌫⌫⌫⌫⌫⌫s", "uss"),
        ("chuognw ⌫⌫⌫⌫ngw ", "chương "), ("thuowr ⌫⌫", "thu"), ("vieejt⎋⌫⎋", "việ"),
    ])
    func unchangedRows(keys: String, expected: String) throws {
        #expect(try Self.text(keys) == expected, "\(keys)")
    }
}
