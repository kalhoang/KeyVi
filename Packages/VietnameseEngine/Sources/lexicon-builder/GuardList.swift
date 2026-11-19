// SPDX-License-Identifier: MPL-2.0
//
// The guard list of the typo correction (spec/01-engine.md 11A, ENG-R1120): the rarer English words and proper names
// of SCOWL that the correction must leave alone, shipped as a Bloom filter (`ApproximateWordSet`) in
// `guard-list.bloom` (resource format 3, data/README.md). A false "yes" only suppresses a correction.

import Foundation
import VietnameseEngine

enum GuardList {
    /// Bit positions per word.
    static let hashCount = 8
    /// The analytic false-positive rate the builder sizes the filter for; ENG-T56 allows 0.5 % measured.
    static let targetFalsePositiveRate = 0.004
    /// ENG-R1120: the guard list takes at most 512 KB resident.
    static let maximumBytes = 512 * 1024
    /// ENG-R1111: a typed word of fewer than five letters is never a candidate, so shorter guard words are useless.
    static let minimumLetters = 5
    static let magic = Array("KVGL".utf8)
    static let version: UInt32 = 1
    static let headerBytes = 32

    /// The guard words: the lowercase `a-z` entries of five letters or more of every guard list member
    /// (`Scowl.guardListFiles`, ISO-8859-1), minus the correction lexicon. Proper names are lowercased; entries with
    /// an apostrophe, a hyphen or a letter outside `a-z` are dropped. A missing member fails the build.
    static func words(_ layout: Layout, lexicon: Set<String>) throws -> Set<String> {
        var words = Set<String>()
        for file in Scowl.guardListFiles {
            let url = layout.scowlDirectory.appendingPathComponent(file)
            guard let text = String(data: try FileIO.read(url), encoding: .isoLatin1) else {
                throw BuilderError("\(url.path) is not ISO-8859-1")
            }
            for raw in text.split(whereSeparator: \.isNewline) {
                let word = raw.trimmingCharacters(in: .whitespaces).lowercased()
                guard word.utf8.count >= minimumLetters, word.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else {
                    continue
                }
                if !lexicon.contains(word) { words.insert(word) }
            }
        }
        return words
    }

    /// (1 - e^(-k n / m))^k, the false-positive rate of a Bloom filter of `bits` bits holding `words` words with
    /// `hashes` hash functions.
    static func falsePositiveRate(words: Int, bits: Int, hashes: Int) -> Double {
        guard words > 0 else { return 0 }
        return pow(1 - exp(-Double(hashes) * Double(words) / Double(bits)), Double(hashes))
    }

    /// The smallest power of two of at least 64 bits whose analytic false-positive rate is at most the target.
    static func bitCount(forWords count: Int) -> Int {
        var bits = 64
        while falsePositiveRate(words: count, bits: bits, hashes: hashCount) > targetFalsePositiveRate { bits <<= 1 }
        return bits
    }

    static func filter(_ words: Set<String>) -> ApproximateWordSet {
        ApproximateWordSet(exactly: words, bitCount: bitCount(forWords: words.count), hashCount: hashCount)
    }

    /// `guard-list.bloom`: a 32-byte header (`KVGL`, `UInt32` version 1, `UInt32` hashCount, `UInt64` bitCount,
    /// `UInt64` wordCount, 4 zero bytes), then the bits as little-endian `UInt64`. Fails above 512 KB (ENG-R1120).
    static func encode(_ filter: ApproximateWordSet) throws -> Data {
        var data = Data(magic)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(version)
        append(UInt32(filter.hashCount))
        append(UInt64(filter.bits.count * 64))
        append(UInt64(filter.wordCount))
        append(UInt32(0))
        for word in filter.bits { append(word) }
        guard data.count <= maximumBytes else {
            throw BuilderError(
                "guard-list.bloom would take \(data.count) bytes, more than the \(maximumBytes) of ENG-R1120")
        }
        return data
    }
}
