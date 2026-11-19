// SPDX-License-Identifier: MPL-2.0
//
// The lookup structures of the typo correction (section 11A, ENG-R1122), derived from `Resources.english`,
// `Resources.techAlways` and `Resources.correction` when the resources are built, and rebuilt when one of those three
// fields is assigned (`Resources`, PublicAPI.swift). A resources value and every copy of it share one index, so the
// engines of a catalog share it too.
//
// Why the index can never be stale: the same prefilter gates the ENG-R1125 pass, so a stale index would not only
// miss corrections but also let `pahir` become `pair` (a keying missing from the prefilter is never looked up).

/// The prefilter and the byte-keyed membership the edit search of section 11A reads (ENG-R1122). Immutable: `let`
/// properties only (ENG-R1203).
package final class CorrectionIndex: Sendable {
    /// One bit per lowercase trigram (26 x 26 x 26) found in any word an edit may reach: the correction lexicon,
    /// the unmarked shapes and the Vietnamese keyings.
    private let trigrams: [UInt64]
    /// One bit per lowercase bigram that starts such a word (`^ab`) and one per bigram that ends one (`yz$`).
    private let starts: [UInt64]
    private let ends: [UInt64]
    /// The correction lexicon (ENG-R1114) and the Vietnamese sets (ENG-R1125): the lists themselves for words of a
    /// small string's length, and byte-keyed tables for the longer words.
    private let english: WordSet
    private let techAlways: WordSet
    private let longLexicon: ByteWordTable
    private let shapes: WordSet
    private let keyings: WordSet
    private let longVietnamese: ByteWordTable

    /// The index of `english`, `techAlways` and the shapes and keyings of `correction`. Allocates while it builds
    /// (where the host builds a catalog, never on the tap).
    package init(english: WordSet, techAlways: WordSet, correction: CorrectionData) {
        var prefilter = Prefilter()
        let longLexiconWords = prefilter.insert([english, techAlways], longerThan: Self.smallStringBytes)
        let longVietnameseWords = prefilter.insert(
            [correction.unmarkedShapes, correction.vietnameseKeyings], longerThan: Self.smallStringBytes)
        trigrams = prefilter.trigrams
        starts = prefilter.starts
        ends = prefilter.ends
        self.english = english
        self.techAlways = techAlways
        longLexicon = ByteWordTable(longLexiconWords)
        shapes = correction.unmarkedShapes
        keyings = correction.vietnameseKeyings
        longVietnamese = ByteWordTable(longVietnameseWords)
    }

    /// The index of no word: every lookup answers false.
    package static let empty = CorrectionIndex(english: WordSet([]), techAlways: WordSet([]), correction: .empty)

    /// The trigram and edge-bigram prefilter: false when `candidate` holds a byte outside `a` to `z`, starts or ends
    /// with a bigram no indexed word starts or ends with, or holds a trigram no indexed word holds. A false "yes"
    /// only costs the lookups behind it; a false "no" never happens for an indexed word. Allocates nothing.
    package func mightHold(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = candidate.count
        guard count >= 2 else { return count == 1 && ASCII.isLowercaseLetter(candidate[0]) }
        var previous = Int(candidate[0]) &- Self.a
        var current = Int(candidate[1]) &- Self.a
        guard Self.isLetterIndex(previous), Self.isLetterIndex(current), Self.bit(starts, previous * 26 + current)
        else { return false }
        var index = 2
        while index < count {
            let next = Int(candidate[index]) &- Self.a
            guard Self.isLetterIndex(next), Self.bit(trigrams, (previous * 26 + current) * 26 + next) else {
                return false
            }
            previous = current
            current = next
            index += 1
        }
        return Self.bit(ends, previous * 26 + current)
    }

    /// Membership in the correction lexicon (ENG-R1114): the English lexicon and the letter-only entries of the
    /// tech-always list. Keyed by bytes; allocates nothing at any length (a word of a small string's length is
    /// looked up as a small `String`, which lives inline; a longer one in a byte-keyed table).
    package func lexiconContains(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !candidate.isEmpty, Self.isLetters(candidate) else { return false }
        guard candidate.count <= Self.smallStringBytes else { return longLexicon.contains(candidate) }
        let word = String(decoding: candidate, as: UTF8.self)
        return english.contains(word) || techAlways.contains(word)
    }

    /// Membership in the Vietnamese keyings or the unmarked shapes (ENG-R1125, ENG-R1110 (d)), the same way as
    /// `lexiconContains`.
    package func isVietnameseKeyingOrShape(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !candidate.isEmpty, Self.isLetters(candidate) else { return false }
        guard candidate.count <= Self.smallStringBytes else { return longVietnamese.contains(candidate) }
        guard candidate.count <= max(keyings.maximumUTF8Count, shapes.maximumUTF8Count) else { return false }
        let word = String(decoding: candidate, as: UTF8.self)
        return keyings.contains(word) || shapes.contains(word)
    }

    /// The UTF-8 length up to which a `String` is stored inline, without a heap allocation.
    private static let smallStringBytes = 15
    private static let a = Int(UInt8(ascii: "a"))

    @inline(__always)
    private static func isLetterIndex(_ index: Int) -> Bool { index >= 0 && index < 26 }

    @inline(__always)
    private static func bit(_ table: [UInt64], _ index: Int) -> Bool {
        table[index >> 6] & (1 << UInt64(index & 63)) != 0
    }

    @inline(__always)
    private static func isLetters(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        while index < bytes.count {
            guard ASCII.isLowercaseLetter(bytes[index]) else { return false }
            index += 1
        }
        return true
    }

    /// The bit tables while the index is built.
    private struct Prefilter {
        var trigrams = [UInt64](repeating: 0, count: (26 * 26 * 26 + 63) / 64)
        var starts = [UInt64](repeating: 0, count: (26 * 26 + 63) / 64)
        var ends = [UInt64](repeating: 0, count: (26 * 26 + 63) / 64)

        /// Adds the bigrams and trigrams of every word of `sets` made of the letters `a` to `z` only (no edit of a
        /// candidate produces another byte) and returns the bytes of those longer than `limit`. One pass over raw
        /// buffers, so the bundled lists index within the load budget of ENG-R1231 in a debug build too.
        mutating func insert(_ sets: [WordSet], longerThan limit: Int) -> [[UInt8]] {
            var long: [[UInt8]] = []
            trigrams.withUnsafeMutableBufferPointer { trigrams in
                starts.withUnsafeMutableBufferPointer { starts in
                    ends.withUnsafeMutableBufferPointer { ends in
                        let tables = Tables(trigrams: trigrams, starts: starts, ends: ends)
                        for set in sets {
                            for word in set.storage {
                                let inserted = word.utf8.withContiguousStorageIfAvailable(tables.insert) ?? false
                                if inserted, word.utf8.count > limit { long.append(Array(word.utf8)) }
                            }
                        }
                    }
                }
            }
            return long
        }

        private struct Tables {
            let trigrams: UnsafeMutableBufferPointer<UInt64>
            let starts: UnsafeMutableBufferPointer<UInt64>
            let ends: UnsafeMutableBufferPointer<UInt64>

            func insert(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
                let count = bytes.count
                var index = 0
                while index < count {
                    guard ASCII.isLowercaseLetter(bytes[index]) else { return false }
                    index += 1
                }
                guard count >= 2 else { return count == 1 }
                var previous = Int(bytes[0]) &- CorrectionIndex.a
                var current = Int(bytes[1]) &- CorrectionIndex.a
                Self.set(starts, previous * 26 + current)
                index = 2
                while index < count {
                    let next = Int(bytes[index]) &- CorrectionIndex.a
                    Self.set(trigrams, (previous * 26 + current) * 26 + next)
                    previous = current
                    current = next
                    index += 1
                }
                Self.set(ends, previous * 26 + current)
                return true
            }

            @inline(__always)
            private static func set(_ table: UnsafeMutableBufferPointer<UInt64>, _ index: Int) {
                table[index >> 6] |= 1 << UInt64(index & 63)
            }
        }
    }
}

/// A set of byte strings with lookups that allocate nothing: an open-addressing table of FNV-1a hashes whose slots
/// point into one store of length-prefixed words, verified byte for byte (ENG-R1122). For the few words longer than
/// a small string.
private struct ByteWordTable: Sendable {
    /// Length-prefixed words, one after the other (every word is at most 255 bytes; longer ones are never stored,
    /// as no edit of a candidate of at most 24 letters reaches them).
    private let store: [UInt8]
    /// `offset + 1` of a word in `store`, 0 for an empty slot; the count is a power of two at least twice the words.
    private let slots: [UInt32]

    init(_ words: [[UInt8]]) {
        let distinct = Array(Set(words.filter { $0.count <= Int(UInt8.max) }))
        var capacity = 1
        while capacity < distinct.count * 2 { capacity <<= 1 }
        var store: [UInt8] = []
        var slots = [UInt32](repeating: 0, count: distinct.isEmpty ? 0 : capacity)
        let mask = capacity - 1
        for word in distinct.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            var slot = word.withUnsafeBufferPointer { Int(truncatingIfNeeded: Self.hash($0)) } & mask
            while slots[slot] != 0 { slot = (slot + 1) & mask }
            slots[slot] = UInt32(store.count + 1)
            store.append(UInt8(word.count))
            store.append(contentsOf: word)
        }
        self.store = store
        self.slots = slots
    }

    func contains(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !slots.isEmpty else { return false }
        let mask = slots.count - 1
        var slot = Int(truncatingIfNeeded: Self.hash(bytes)) & mask
        while slots[slot] != 0 {
            let offset = Int(slots[slot] - 1)
            if Int(store[offset]) == bytes.count, matches(bytes, at: offset + 1) { return true }
            slot = (slot + 1) & mask
        }
        return false
    }

    private func matches(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
        var index = 0
        while index < bytes.count {
            guard store[offset + index] == bytes[index] else { return false }
            index += 1
        }
        return true
    }

    /// FNV-1a 64 over the bytes (never Swift's `Hasher`, which is seeded per process).
    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var index = 0
        while index < bytes.count {
            hash = (hash ^ UInt64(bytes[index])) &* 0x0000_0100_0000_01B3
            index += 1
        }
        return hash
    }
}
