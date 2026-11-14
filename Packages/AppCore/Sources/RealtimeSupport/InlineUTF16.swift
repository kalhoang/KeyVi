// SPDX-License-Identifier: GPL-3.0-or-later

/// Fixed-capacity UTF-16 buffer (at most 20 code units, the practical limit of
/// `CGEventKeyboardSetUnicodeString`, PLT-R404). Bitwise-copyable so events can be held, queued and
/// replayed on the hot path without heap allocation.
public struct InlineUTF16: Sendable, Hashable, BitwiseCopyable {
    public static let capacity = 20

    public private(set) var count: UInt8
    private var units:
        (
            UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
            UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
        )

    public static let empty = InlineUTF16()

    public init() {
        count = 0
        units = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// Copies at most `capacity` units from a buffer (tap thread: buffer filled by
    /// `CGEventKeyboardGetUnicodeString`). Returns nil if the source is longer than the capacity.
    public init?(_ buffer: UnsafeBufferPointer<UInt16>) {
        guard buffer.count <= Self.capacity else { return nil }
        self.init()
        withUnsafeMutableBytes(of: &units) { raw in
            let target = raw.bindMemory(to: UInt16.self)
            // A `while` loop: an unoptimised `for ... in` over a range allocates an iterator box per iteration, and
            // Debug builds (the dev recorder's, PLT-R904A) run this on the tap (PLT-R305).
            var index = 0
            while index < buffer.count {
                target[index] = buffer[index]
                index += 1
            }
        }
        count = UInt8(buffer.count)
    }

    /// Non-tap threads only (allocates when reading the string's UTF-16 view of a large string).
    public init?(_ string: some StringProtocol) {
        let utf16 = Array(string.utf16)
        let built = utf16.withUnsafeBufferPointer { InlineUTF16($0) }
        guard let built else { return nil }
        self = built
    }

    /// Calls `body` with the stored units, without allocating.
    public func withUnits<Result>(_ body: (UnsafeBufferPointer<UInt16>) throws -> Result) rethrows -> Result {
        try withUnsafeBytes(of: units) { raw in
            try body(UnsafeBufferPointer(start: raw.bindMemory(to: UInt16.self).baseAddress, count: Int(count)))
        }
    }

    /// Allocates; never call on the tap thread.
    public var string: String { withUnits { String(decoding: $0, as: UTF16.self) } }

    public static func == (lhs: InlineUTF16, rhs: InlineUTF16) -> Bool {
        lhs.withUnits { left in rhs.withUnits { right in left.elementsEqual(right) } }
    }

    public func hash(into hasher: inout Hasher) { withUnits { hasher.combine(bytes: UnsafeRawBufferPointer($0)) } }
}
