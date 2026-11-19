// SPDX-License-Identifier: MPL-2.0
//
// The membership structure of the unmarked shapes and the Vietnamese keyings of section 11A (ENG-R1110 (d),
// ENG-R1125), spec 12.2 as amended a sixth time on 19/11/2026: a `Set<String>` keeps its load under 75 %, so the
// 27,277 bundled keyings took 1 MB of buckets alone, over the 1 MB that ENG-R1120 allows all the new data
// (docs/decisions/0203-correction-data.md sections 6 and 8).
//
// Packing, written once here and used by the loader (VietnameseEngineData) and the correction index: a word of 1 to
// 12 letters `a` to `z` is one `UInt64`, 5 bits per letter (`a` is 1, `z` is 26, 0 marks the end), the first letter
// in the highest of the 60 low bits. A letter is never 0, so a word and its prefixes stay distinct, and the values
// sort as the words' bytes do: the sorted bundled files become the sorted array without a sort. A lookup is a binary
// search over that array (15 probes at most for the 27,277 keyings), allocates nothing and is bounded by the data,
// not by the token (ENG-R1122). Any other word (longer, or with a character outside `a` to `z`) is kept apart in an
// ordinary set, empty for the bundled data, so the type takes any words and never answers wrongly.

/// An immutable set of lowercase words stored compactly: every word of 1 to 12 letters `a` to `z` as one packed
/// `UInt64` in a sorted array, any other word in an ordinary set beside it (ENG-R1120, spec 12.2).
public struct PackedWordSet: Sendable {
    /// The words of 1 to 12 letters `a` to `z`, packed, strictly ascending, without spare capacity.
    let packed: [UInt64]
    /// The words that do not pack; empty for the bundled shapes and keyings.
    let others: WordSet

    /// The longest word that packs: 12 letters of 5 bits fill 60 of the 64 bits. Computed rather than stored, so a
    /// debug build reads them without a lazy-global check in the loops of the load (ENG-R1231).
    static var maximumLetters: Int { 12 }
    private static var bitsPerLetter: Int { 5 }

    /// A set of `words` (compared byte for byte, so callers pass lowercased words); duplicates are ignored and the
    /// words may come in any order.
    public init<S: Sequence>(_ words: S) where S.Element == String {
        var packed: [UInt64] = []
        packed.reserveCapacity(words.underestimatedCount)
        var others: [String] = []
        for word in words {
            if let value = Self.pack(utf8: word.utf8) { packed.append(value) } else { others.append(word) }
        }
        self.init(packed: packed.capacity > packed.count ? Self.exactCopy(packed) : packed, others: WordSet(others))
    }

    /// A set of packed values (`pack(utf8:)`) and the words that do not pack. The loader passes the values in the
    /// order of the sorted file, which is the set's order, in an array of exactly their count, so they are only
    /// checked and kept as they are (ENG-R1231); any other order is sorted, duplicates are dropped and the result is
    /// copied to storage of exactly its count.
    package init(packed values: [UInt64], others: WordSet = WordSet([])) {
        var ascending = true
        var index = 1
        while ascending, index < values.count {
            ascending = values[index - 1] < values[index]
            index += 1
        }
        if ascending {
            packed = values
        } else {
            var result = values.sorted()
            var kept = 1
            for index in result.indices.dropFirst() where result[index] != result[kept - 1] {
                result[kept] = result[index]
                kept += 1
            }
            result.removeSubrange(kept...)
            packed = Self.exactCopy(result)
        }
        self.others = others
    }

    /// The number of distinct words.
    public var count: Int { packed.count + others.storage.count }

    /// Whether `word` is in the set (exact match; callers pass lowercased text).
    public func contains(_ word: some StringProtocol) -> Bool {
        if let value = Self.pack(utf8: word.utf8) { return contains(packed: value) }
        return others.contains(word)
    }

    /// `contains` over UTF-8 bytes, for callers that hold a byte buffer (the edit search of section 11A). Allocates
    /// nothing for a word that packs, nor for any word when every word of the set packs (the bundled data);
    /// otherwise a word longer than a small string is copied once to look it up among the others (ENG-R1122).
    package func contains<Bytes: Collection>(utf8 bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        if let value = Self.pack(utf8: bytes) { return contains(packed: value) }
        guard !others.storage.isEmpty else { return false }
        return others.contains(String(decoding: bytes, as: UTF8.self))
    }

    /// Whether the set holds the word of a packed value: a binary search of the sorted array.
    func contains(packed value: UInt64) -> Bool {
        var low = 0
        var high = packed.count
        while low < high {
            let middle = low + (high - low) / 2
            let probe = packed[middle]
            if probe == value { return true }
            if probe < value { low = middle + 1 } else { high = middle }
        }
        return false
    }

    /// Whether `other` reads the same packed array, not a copy of it (the correction index reads the sets in place,
    /// ENG-R1120).
    package func sharesStorage(with other: PackedWordSet) -> Bool {
        packed.withUnsafeBufferPointer { mine in
            other.packed.withUnsafeBufferPointer { theirs in mine.baseAddress == theirs.baseAddress }
        } && packed.count == other.packed.count
    }

    /// The set that holds no word.
    public static let empty = PackedWordSet(packed: [])

    /// The packed value of a word of 1 to 12 letters `a` to `z`, nil for any other bytes.
    @inline(__always)
    package static func pack<Bytes: Sequence>(utf8 bytes: Bytes) -> UInt64? where Bytes.Element == UInt8 {
        var value: UInt64 = 0
        var letters = 0
        for byte in bytes {
            guard byte >= 0x61, byte <= 0x7A, letters < maximumLetters else { return nil }
            value = value << UInt64(bitsPerLetter) | UInt64(byte &- 0x60)
            letters += 1
        }
        guard letters > 0 else { return nil }
        return value << UInt64(bitsPerLetter * (maximumLetters - letters))
    }

    /// `pack(utf8:)` over a byte buffer without generics, for the loader and the edit search (ENG-R1231, ENG-R1122).
    @inline(__always)
    package static func pack(utf8 bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        let count = bytes.count
        guard count > 0, count <= 12, let base = bytes.baseAddress else { return nil }
        var value: UInt64 = 0
        var index = 0
        while index < count {
            let byte = base[index]
            guard byte >= 0x61, byte <= 0x7A else { return nil }
            value = value &<< 5 | UInt64(byte &- 0x60)
            index &+= 1
        }
        return value &<< UInt64(5 &* (12 &- count))
    }

    /// The code of the letter at `index` (0 to 11) of a packed value: 1 for `a` to 26 for `z`, 0 past the word's end.
    @inline(__always)
    static func letterCode(_ value: UInt64, at index: Int) -> Int {
        Int(truncatingIfNeeded: value &>> UInt64(5 &* (11 &- index))) & 0x1F
    }

    /// A copy of `values` in storage of exactly their count, so the array's footprint is its words (ENG-R1120).
    private static func exactCopy(_ values: [UInt64]) -> [UInt64] {
        [UInt64](unsafeUninitializedCapacity: values.count) { buffer, initialized in
            _ = buffer.initialize(from: values)
            initialized = values.count
        }
    }
}
