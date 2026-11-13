// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R422 and the section 4 acceptance: the zero-width placeholder is allowed only in a rule whose test shows
// zero leftover placeholders over at least 1,000 randomised edits at burst typing speed. A scenario file declares
// that test with a `repeat` block and `expect.noPlaceholderResidue` (compat/schema/scenario.schema.json, run by
// TestSupport's `ScenarioRunner`). `compat-lint` reads the declaration from the file; the runner enforces it.

public import AppModel

public enum PlaceholderGate {
    /// Fewest randomised words a gate scenario types (PLT-R422 "at least 1,000 randomised edits").
    public static let minimumWords = 1_000
    /// `repeat.timing` a gate scenario must use (PLT-R422 "at burst typing speed").
    public static let timing = "burst"
    /// Readbacks that check every word without a person; `human` cannot confirm 1,000 words.
    public static let automaticReadbacks: Set<String> = ["ax", "webdriver"]

    /// True when the scenario document declares the gate: `repeat.words` at least `minimumWords` at
    /// `repeat.timing` burst, `expect.noPlaceholderResidue: true` and an automatic readback.
    public static func isDeclared(in scenario: JSONValue) -> Bool {
        guard let repetition = scenario["repeat"], let words = repetition["words"]?.intValue,
            let readback = scenario["readback"]?.stringValue
        else { return false }
        return words >= minimumWords && repetition["timing"]?.stringValue == timing
            && scenario["expect"]?["noPlaceholderResidue"] == .bool(true) && automaticReadbacks.contains(readback)
    }
}
