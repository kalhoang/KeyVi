// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Requirements that the traceability review found without a dedicated test.
@Suite("Traceability gaps closed")
struct RequirementGapTests {
    @Test("ENG-R421 literal mode ends when Backspace removes the key that caused it")
    func literalModeEndsWithItsKey() throws {
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false))
        try driver.type("tieengks")
        #expect(driver.state.isLiteral && driver.field.string == "tiêngks")  // s appended verbatim (ENG-R420)
        try driver.type("⌫")
        #expect(driver.state.isLiteral && driver.field.string == "tiêngk")  // still literal: k caused it
        try driver.type("⌫")
        #expect(!driver.state.isLiteral && driver.field.string == "tiêng")  // recomputed (ENG-R601)
        try driver.type("s")
        #expect(driver.field.string == "tiếng")
    }

    @Test("ENG-R1106 a rejected macro table never reports an expansion")
    func validationErrorsCarryNoExpansion() {
        let secret = "secret expansion text"
        let tables: [[MacroTable.Entry]] = [
            [.init(trigger: "", expansion: secret)],
            [.init(trigger: String(repeating: "a", count: 33), expansion: secret)],
            [.init(trigger: "a b", expansion: secret)],
            [.init(trigger: "x", expansion: String(repeating: "y", count: 4_001))],
            [.init(trigger: "vn", expansion: secret), .init(trigger: "VN", expansion: secret)],
            [.init(trigger: "ad", expansion: secret), .init(trigger: "ad.", expansion: secret)],
        ]
        for entries in tables {
            do {
                _ = try MacroTable(entries)
                Issue.record("accepted \(entries.map(\.trigger))")
            } catch {
                #expect(!String(describing: error).contains(secret) && !String(describing: error).contains("yyyy"))
            }
        }
    }

    @Test("ENG-R841, ENG-R842 toggled tokens and unchanged tokens are never changed by commit")
    func neverRestored() throws {
        let resources = SpecFixtures.commitResources()
        func commit(_ keys: String) throws -> (String, CommitDecision?) {
            var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false), resources: resources)
            try driver.send(KeyNotation.events(keys))
            return (driver.field.string, driver.outputs.last?.decision)
        }
        // User-kept: `test` would be restored by its `en` row; after the toggle it stays Vietnamese.
        let kept = try commit("test \u{232B}\u{238B} ")
        #expect(kept.0 == "tét " && kept.1 == .kept(.userChoice))
        // User-restored: `việt` would be kept; after the toggle the keys stay.
        let restored = try commit("vieejt\u{238B} ")
        #expect(restored.0 == "vieejt " && restored.1 == .restored(.userChoice))
        // Unchanged (L0).
        let unchanged = try commit("mother ")
        #expect(unchanged.0 == "mother " && unchanged.1 == .kept(.unchanged))
    }
}
