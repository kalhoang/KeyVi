// SPDX-License-Identifier: MPL-2.0

/// A lowercased macro trigger or span of at most 32 printable ASCII characters, packed into four words so
/// that the lookup of ENG-R1105 hashes a fixed-size value and allocates nothing.
package struct MacroKey: Sendable, Hashable {
    /// ENG-R1101, ENG-R1102: triggers and matchable spans hold at most 32 characters.
    package static let capacity = 32

    private var word0: UInt64 = 0
    private var word1: UInt64 = 0
    private var word2: UInt64 = 0
    private var word3: UInt64 = 0
    package private(set) var count: UInt8 = 0

    package init() {}

    /// The key of `bytes`, folded to lowercase (ASCII only, ENG-R905). Nil when there are more than 32
    /// bytes or a byte is not printable ASCII (`0x21...0x7E`; triggers contain no whitespace).
    package init?(lowercasing bytes: some Sequence<UInt8>) {
        for byte in bytes {
            guard Self.isTriggerByte(byte), append(ASCII.lowercased(byte)) else { return nil }
        }
    }

    /// Printable ASCII without the space (ENG-R1101).
    @inline(__always)
    package static func isTriggerByte(_ byte: UInt8) -> Bool { byte > 0x20 && byte < 0x7F }

    /// Appends one byte; false when the key is full.
    @inline(__always)
    private mutating func append(_ byte: UInt8) -> Bool {
        guard Int(count) < Self.capacity else { return false }
        let shift = UInt64(count % 8) * 8
        let value = UInt64(byte) << shift
        switch count / 8 {
        case 0: word0 |= value
        case 1: word1 |= value
        case 2: word2 |= value
        default: word3 |= value
        }
        count += 1
        return true
    }
}
