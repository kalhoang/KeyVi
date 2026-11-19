// SPDX-License-Identifier: MPL-2.0
//
// The guard list of the typo correction (spec/01-engine.md ENG-R1120): its words, the choice of the filter's size and
// the bytes of `guard-list.bloom` (data/README.md, resource format 3). The real inputs are covered by
// LexiconBuilderTests; ENG-T56 measures the false positives in CorrectionDataTests.

import Foundation
import Testing
import VietnameseEngine

@testable import lexicon_builder

@Suite struct GuardListTests {
    @Test func guardWordsAreLowercaseLettersOfFiveOrMoreOutsideTheLexicon() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        try write(
            "Hanoi\nHUE\nSaigon\nmy-way\nCafé\nnaïve\nShort\n",
            to: layout.scowlDirectory.appendingPathComponent("american-proper-names.50"))
        try write("theme\nthemes\nwifis\n", to: layout.scowlDirectory.appendingPathComponent("british-words.70"))
        let words = try GuardList.words(layout, lexicon: ["themes", "short"])
        #expect(words.isSuperset(of: ["hanoi", "saigon", "zebra", "quixotic", "biden", "kbang", "wifis", "theme"]))
        for excluded in ["hue", "my-way", "café", "naïve", "themes", "short", "ann", "o'brien"] {
            #expect(!words.contains(excluded), "\(excluded)")
        }
    }

    @Test func aMissingGuardMemberFailsTheBuild() throws {
        let root = try MiniDataRoot.make()
        defer { TempDirectory.remove(root) }
        let layout = Layout(dataRoot: root.appendingPathComponent("data"), resources: root)
        try FileManager.default.removeItem(at: layout.scowlDirectory.appendingPathComponent("american-proper-names.50"))
        #expect(throws: BuilderError.self) { try GuardList.words(layout, lexicon: []) }
    }

    /// The smallest power of two of at least 64 bits whose analytic rate (1 - e^(-kn/m))^k is at most 0.4 %.
    @Test func theFilterSizeIsTheSmallestPowerOfTwoUnderTheTargetRate() {
        #expect(GuardList.bitCount(forWords: 0) == 64)
        #expect(GuardList.bitCount(forWords: 1) == 64)
        for count in [5, 100, 10_000, 77_488] {
            let bits = GuardList.bitCount(forWords: count)
            #expect(bits & (bits - 1) == 0 && bits >= 64)
            #expect(GuardList.falsePositiveRate(words: count, bits: bits, hashes: 8) <= 0.004, "\(count)")
            if bits > 64 {
                #expect(GuardList.falsePositiveRate(words: count, bits: bits / 2, hashes: 8) > 0.004, "\(count)")
            }
        }
        #expect(GuardList.bitCount(forWords: 77_488) == 1 << 20)
        let filter = GuardList.filter(["biden", "kbang", "quixotic"])
        #expect(filter.hashCount == 8 && filter.wordCount == 3 && filter.bits.count == 1)
        #expect(filter.mayContain("biden") && filter.mayContain("kbang") && filter.mayContain("quixotic"))
    }

    @Test func theFileIsAHeaderThenLittleEndianBits() throws {
        let filter = ApproximateWordSet(exactly: ["biden"], bitCount: 128, hashCount: 8)
        let data = try GuardList.encode(filter)
        #expect(data.count == 32 + 16)
        #expect(Array(data[0..<4]) == Array("KVGL".utf8))
        #expect(Array(data[4..<8]) == [1, 0, 0, 0], "version 1")
        #expect(Array(data[8..<12]) == [8, 0, 0, 0], "hash count")
        #expect(Array(data[12..<20]) == [128, 0, 0, 0, 0, 0, 0, 0], "bit count")
        #expect(Array(data[20..<28]) == [1, 0, 0, 0, 0, 0, 0, 0], "word count")
        #expect(Array(data[28..<32]) == [0, 0, 0, 0])
        for (index, word) in filter.bits.enumerated() {
            let bytes = Array(data[(32 + index * 8)..<(40 + index * 8)])
            #expect(bytes == (0..<8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) })
        }
        #expect(data == GuardListFixture.encode(filter), "the documented layout")
    }

    /// ENG-R1120: the build fails when the file would take more than 512 KB.
    @Test func aFileOver512KBFailsTheBuild() throws {
        let largest = ApproximateWordSet(exactly: ["biden"], bitCount: 1 << 21, hashCount: 8)
        #expect(try GuardList.encode(largest).count == 32 + 256 * 1024)
        let tooLarge = ApproximateWordSet(exactly: ["biden"], bitCount: 1 << 22, hashCount: 8)
        #expect(throws: BuilderError.self) { try GuardList.encode(tooLarge) }
    }
}
