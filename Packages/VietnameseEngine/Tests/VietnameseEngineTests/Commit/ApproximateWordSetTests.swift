// SPDX-License-Identifier: MPL-2.0
//
// `ApproximateWordSet`, the membership structure of the guard list (spec/01-engine.md ENG-R1120 and 12.2 as amended
// by the API stage of 1.1.0): a Bloom filter that never answers "no" for a word it was built from and answers "yes"
// for a word it lacks at most at the configured rate. Its hashing has no process seed (FNV-1a with double hashing),
// so `lexicon-builder` and the loader agree on every bit.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ApproximateWordSet, the guard list's filter (ENG-R1120)")
struct ApproximateWordSetTests {
    /// `count` distinct random lowercase words of 5 to 12 letters, none of them in `excluding`.
    static func randomWords(count: Int, seed: UInt64, excluding: Set<String> = []) -> [String] {
        var generator = SeededGenerator(seed: seed)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var seen = excluding
        var words: [String] = []
        words.reserveCapacity(count)
        while words.count < count {
            let length = Int.random(in: 5...12, using: &generator)
            let word = String((0..<length).map { _ in letters[Int.random(in: 0..<26, using: &generator)] })
            if seen.insert(word).inserted { words.append(word) }
        }
        return words
    }

    @Test("Never forgets a word it was built from (no false no)")
    func neverForgetsAWordItWasBuiltFrom() {
        let words = Self.randomWords(count: 10_000, seed: 19_112_026)
        let set = ApproximateWordSet(exactly: words)
        #expect(set.wordCount == 10_000)
        let forgotten = words.filter { !set.mayContain($0) }
        #expect(forgotten.isEmpty, "\(forgotten.prefix(10))")
    }

    @Test("ENG-R1120: at 12 bits per word, at most 0.5 % of other words answer yes")
    func falsePositivesStayUnderTheRate() {
        let words = Self.randomWords(count: 100_000, seed: 18_112_026)
        let set = ApproximateWordSet(exactly: words, bitsPerWord: 12)
        let others = Self.randomWords(count: 100_000, seed: 7, excluding: Set(words))
        let falseYes = others.filter { set.mayContain($0) }.count
        #expect(falseYes <= 500, "\(falseYes) false positives in 100,000")
    }

    @Test("The bits round-trip and two builds from the same words are equal (no process seed)")
    func bitsRoundTripAndAreDeterministic() {
        let words = Self.randomWords(count: 2_000, seed: 42)
        let built = ApproximateWordSet(exactly: words)
        let reversed = ApproximateWordSet(exactly: words.reversed())
        #expect(built.bits == reversed.bits)
        let loaded = ApproximateWordSet(bits: built.bits, hashCount: built.hashCount, wordCount: built.wordCount)
        #expect(loaded.bits == built.bits && loaded.hashCount == built.hashCount)
        #expect(loaded.wordCount == built.wordCount)
        for word in words { #expect(loaded.mayContain(word)) }
        for word in Self.randomWords(count: 2_000, seed: 43, excluding: Set(words)) {
            #expect(loaded.mayContain(word) == built.mayContain(word))
        }
    }

    @Test("The hashing is FNV-1a 64 with double hashing, written once for the builder and the loader")
    func theHashingIsPinned() {
        // Expected bits computed independently from the formula of 12.2 as amended (FNV-1a 64 over the UTF-8 bytes
        // gives h1; h2 is h1 rotated left by 32 bits, forced odd; index i is (h1 + i * h2) & (bitCount - 1)):
        // `android` sets bits 620, 313 and 6, `grammar` bits 542, 697 and 852 of 1,024 with three hashes.
        let set = ApproximateWordSet(exactly: ["android", "grammar"], bitCount: 1_024, hashCount: 3)
        var expected = [UInt64](repeating: 0, count: 16)
        for index in [620, 313, 6, 542, 697, 852] { expected[index >> 6] |= 1 << UInt64(index & 63) }
        #expect(set.bits == expected)
        #expect(set.hashCount == 3 && set.wordCount == 2)
        #expect(set.mayContain("android") && set.mayContain("grammar"))
    }

    @Test("The size is the smallest power of two at or above bitsPerWord times the words, at least 64 bits")
    func sizeIsAPowerOfTwo() {
        #expect(ApproximateWordSet(exactly: Self.randomWords(count: 100, seed: 1)).bits.count == 32)  // 1,200 -> 2,048
        #expect(ApproximateWordSet(exactly: [String]()).bits.count == 1)  // 64 bits
        #expect(ApproximateWordSet(exactly: ["androdi"], bitsPerWord: 64).bits.count == 1)
        #expect(ApproximateWordSet(exactly: ["androdi", "gramar"], bitsPerWord: 64).bits.count == 2)
        #expect(ApproximateWordSet(exactly: ["androdi", "androdi"]).wordCount == 1)  // distinct words
        #expect(ApproximateWordSet(exactly: ["androdi"], bitCount: 4_096, hashCount: 8).bits.count == 64)
    }

    @Test("The empty set answers no for every word")
    func emptyAnswersNo() {
        #expect(!ApproximateWordSet.empty.mayContain("android"))
        #expect(!ApproximateWordSet.empty.mayContain(""))
        #expect(ApproximateWordSet.empty.wordCount == 0)
        // A filter built from no word answers no as well: every bit is clear.
        #expect(!ApproximateWordSet(exactly: [String]()).mayContain("android"))
    }
}
