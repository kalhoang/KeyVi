// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The scenario `repeat` block (PLT-R422, section 4 acceptance "1,000 randomised words each, zero duplicates and
// zero leftover placeholders"): seeded words from the Telex soak corpus, each typed after the block's prefix and
// read back on its own. Reasons name the word's index only, never its text (PLT-R901 applies to reports).

internal import CompatRules

/// One word of a `repeat` block: physical keys (Telex) and the text the field must show afterwards.
public struct ScenarioRepetitionWord: Sendable, Hashable {
    public var keys: [String]
    public var text: String

    public init(keys: [String], text: String) {
        self.keys = keys
        self.text = text
    }
}

public enum ScenarioRepetitionPlan {
    /// `repetition.words` words of `SoakCorpus`, the same sequence for the same seed.
    public static func words(for repetition: Scenario.Repetition) -> [ScenarioRepetitionWord] {
        var generator = SeededGenerator(seed: repetition.seed)
        return (0..<max(0, repetition.words)).map { _ in
            let word = SoakCorpus.words[Int(generator.next() % UInt64(SoakCorpus.words.count))]
            return ScenarioRepetitionWord(keys: word.keys.map(String.init), text: word.text)
        }
    }

    /// Keystrokes the block types, prefixes included.
    public static func keystrokes(for repetition: Scenario.Repetition) -> Int {
        words(for: repetition).reduce(0) { $0 + repetition.prefix.count + $1.keys.count }
    }
}

extension Scenario {
    /// The PLT-R422 gate: the same test as CompatRules' `PlaceholderGate.isDeclared` over the file, which is what
    /// `compat-lint` reads.
    public var declaresPlaceholderGate: Bool {
        guard let repetition else { return false }
        return repetition.words >= PlaceholderGate.minimumWords && repetition.timing.rawValue == PlaceholderGate.timing
            && expect.noPlaceholderResidue == true && PlaceholderGate.automaticReadbacks.contains(readback.rawValue)
    }
}

extension Scenario.Expectation {
    /// The field text must be read back: an expected text or the residue check.
    var needsReadback: Bool { text != nil || noPlaceholderResidue == true }
}

/// Why a `repeat` word failed, and what the field showed.
struct RepetitionFailure: Sendable, Hashable {
    var reason: String
    var observed: String
}

extension ScenarioRunner {
    /// Types every word of `repetition` and reads it back; stops at the first word that reads back differently
    /// from its corpus text (a duplicated or lost letter) or, with `expect.noPlaceholderResidue`, holds the
    /// placeholder. `stage` names the word for errors thrown by the driver or the readback.
    func runRepetition(
        _ repetition: Scenario.Repetition, of scenario: Scenario, stage: inout String
    ) async throws -> RepetitionFailure? {
        let words = ScenarioRepetitionPlan.words(for: repetition)
        for (index, word) in words.enumerated() {
            let label = "repeat word \(index + 1) of \(words.count)"
            stage = label + " typing"
            try await driver.type(repetition.prefix + word.keys, profile: repetition.timing)
            stage = label + " readback " + scenario.readback.rawValue
            let text = try await readback.currentText(of: scenario)
            if scenario.expect.noPlaceholderResidue == true, ScenarioVerdict.hasPlaceholderResidue(text) {
                return RepetitionFailure(reason: label + ": leftover placeholder U+200B", observed: text)
            }
            // Swift `String ==` is canonical equivalence, as for the key script's expected text.
            if text != word.text {
                return RepetitionFailure(reason: label + ": observed text differs from the corpus word", observed: text)
            }
        }
        return nil
    }
}
