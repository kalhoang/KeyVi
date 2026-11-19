// SPDX-License-Identifier: MPL-2.0
//
// The membership structure of the guard list of section 11A (ENG-R1120): a Bloom filter over lowercase words. It
// never answers "no" for a word it was built from and answers "yes" for a word it lacks at most at the configured
// rate; a false "yes" only suppresses a correction. Spec 12.2 as amended by the API stage of 1.1.0 (the guard list
// is not a `WordSet`, which cannot answer yes for a word it lacks).
//
// Hashing, written once here and used by `lexicon-builder` (through this type) and the loader: FNV-1a 64 over the
// UTF-8 bytes gives h1; h2 is h1 rotated left by 32 bits, forced odd; the i-th index is
// (h1 &+ UInt64(i) &* h2) & (bitCount - 1). Swift's `Hasher` is never used: it is seeded per process, and the bits
// are written to a file that another process reads.

/// A Bloom filter over lowercase words: never a false "no", at most the configured false "yes" rate (ENG-R1120).
public struct ApproximateWordSet: Sendable {
    /// The filter's bits, bit `i` at `bits[i >> 6] >> (i & 63)`; `bits.count` is a power of two, or zero for the
    /// empty set.
    public let bits: [UInt64]
    /// The number of hash functions (bit positions per word).
    public let hashCount: Int
    /// The number of distinct words the filter was built from.
    public let wordCount: Int

    /// A filter from its stored form (the bundled file). `bits.count` MUST be zero or a power of two and
    /// `hashCount` at least 1 when there are bits; the loader validates the file before calling this.
    public init(bits: [UInt64], hashCount: Int, wordCount: Int) {
        precondition(bits.isEmpty || bits.count & (bits.count - 1) == 0, "bits.count must be a power of two")
        precondition(bits.isEmpty || hashCount >= 1, "hashCount must be at least 1")
        precondition(wordCount >= 0, "wordCount must not be negative")
        self.bits = bits
        self.hashCount = hashCount
        self.wordCount = wordCount
    }

    /// A filter holding `words` (compared byte for byte, so callers pass lowercased words), sized to the smallest
    /// power of two of at least `bitsPerWord` bits per distinct word, and at least 64 bits.
    public init<S: Sequence>(exactly words: S, bitsPerWord: Int = 12, hashCount: Int = 8) where S.Element == String {
        let distinct = Set(words)
        var bitCount = 64
        while bitCount < max(1, bitsPerWord) * distinct.count { bitCount <<= 1 }
        self.init(distinct: distinct, bitCount: bitCount, hashCount: hashCount)
    }

    /// A filter holding `words` in exactly `bitCount` bits, a power of two of at least 64 (the builder's choice of
    /// size, ENG-R1120).
    public init<S: Sequence>(exactly words: S, bitCount: Int, hashCount: Int) where S.Element == String {
        precondition(bitCount >= 64 && bitCount & (bitCount - 1) == 0, "bitCount must be a power of two of 64 or more")
        self.init(distinct: Set(words), bitCount: bitCount, hashCount: hashCount)
    }

    private init(distinct: Set<String>, bitCount: Int, hashCount: Int) {
        precondition(hashCount >= 1, "hashCount must be at least 1")
        var bits = [UInt64](repeating: 0, count: bitCount >> 6)
        let mask = UInt64(bitCount - 1)
        for word in distinct {
            let (h1, h2) = Self.hashes(word.utf8)
            for i in 0..<hashCount {
                let index = Int(truncatingIfNeeded: (h1 &+ UInt64(i) &* h2) & mask)
                bits[index >> 6] |= 1 << UInt64(index & 63)
            }
        }
        self.init(bits: bits, hashCount: hashCount, wordCount: distinct.count)
    }

    /// Whether the filter may hold `word`: false means certainly not; true means held, or a false positive.
    public func mayContain(_ word: some StringProtocol) -> Bool {
        mayContain(utf8: word.utf8)
    }

    /// `mayContain` over UTF-8 bytes, for callers that hold a byte buffer and must not allocate a `String`
    /// (ENG-R1122).
    package func mayContain<Bytes: Sequence>(utf8 bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        guard !bits.isEmpty else { return false }
        let (h1, h2) = Self.hashes(bytes)
        let mask = UInt64(bits.count &* 64 &- 1)
        for i in 0..<hashCount {
            let index = Int(truncatingIfNeeded: (h1 &+ UInt64(i) &* h2) & mask)
            if bits[index >> 6] & (1 << UInt64(index & 63)) == 0 { return false }
        }
        return true
    }

    /// The set that holds no word: it answers false for every word.
    public static let empty = ApproximateWordSet(bits: [], hashCount: 0, wordCount: 0)

    /// h1 (FNV-1a 64) and h2 (h1 rotated left by 32 bits, forced odd) of `bytes`.
    @inline(__always)
    private static func hashes<Bytes: Sequence>(_ bytes: Bytes) -> (UInt64, UInt64) where Bytes.Element == UInt8 {
        var h1: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes { h1 = (h1 ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let h2 = ((h1 << 32) | (h1 >> 32)) | 1
        return (h1, h2)
    }
}
