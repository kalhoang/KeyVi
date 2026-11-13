// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The shortcuts that keep commits of long literal tokens proportional to a copy (REG-02, ENG-R1232) must
/// not change any decision.
@Suite("Long-token shortcuts (ENG-R1232)")
struct LongTokenCostTests {
    @Test("No Tier B syllable is longer than the parse limit of the commit facts")
    func syllableLengthBound() {
        let longest = SyllableTables.extendedPairs.map(\.letters.count).max() ?? 0
        #expect(longest <= CommittedTextFacts.maximumSyllableLetters)
        #expect(CommittedTextFacts("nghiêng").validity == .standard)
        #expect(CommittedTextFacts(String(repeating: "a", count: 9)).validity == .invalid)
        #expect(CommittedTextFacts("Nghiêng" + String(repeating: "x", count: 100)).hasVowel)
    }

    @Test("A word longer than every listed word is rejected, a listed word found")
    func wordSetLengthReject() {
        let words = WordSet(["the", "keyboard", "đường"])
        #expect(words.contains("keyboard") && words.contains("đường") && words.contains("the"[...]))
        #expect(!words.contains("keyboards") && !words.contains(String(repeating: "k", count: 100_000)))
        #expect(!WordSet([]).contains(""))
        #expect(WordSet([""]).contains(""))
    }

    @Test("A long literal token commits and restores like a short one")
    func longLiteralCommit() throws {
        for length in [65, 1_000, 2_000] {
            let keys = "ddam" + String(repeating: "m", count: length)
            var driver = EngineDriver(configuration: EngineConfiguration(), resources: SpecFixtures.commitResources())
            try driver.type(keys + " ")
            #expect(driver.field.string == keys + " ")  // invalid: restored (L5)
            #expect(driver.outputs.last?.decision == .restored(.invalid))
            var plain = EngineDriver(configuration: EngineConfiguration(), resources: SpecFixtures.commitResources())
            try plain.type(String(repeating: "m", count: length) + " ")
            #expect(plain.outputs.last?.decision == .kept(.unchanged))
        }
    }
}
