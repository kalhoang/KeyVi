// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounds the container nesting of a user-chosen property list before `PropertyListSerialization` (a recursive
// parser) sees it, so a crafted file cannot overflow the stack (PLT-R912 spirit applied to macro import).
// Only XML and binary (`bplist00`) plists are accepted; the old OpenStep text format is refused.

internal import Foundation

enum PlistNesting {
    static func isWithinLimit(_ data: Data, limit: Int) -> Bool {
        let bytes = [UInt8](data)
        if bytes.starts(with: MacroPlistParser.binaryMagic) {
            return BinaryPlistNesting.isWithinLimit(bytes, limit: limit)
        }
        guard let first = bytes.firstIndex(where: { !isWhitespace($0) }), bytes[first] == UInt8(ascii: "<") else {
            return false
        }
        return xmlDepth(bytes, limit: limit) != nil
    }

    /// Maximum nesting of `<array>` / `<dict>` elements (self-closing ones excluded), or nil above `limit` or
    /// when a comment, processing instruction, CDATA section or declaration is not terminated. Those spans are
    /// skipped whole, so a closing tag hidden inside one cannot mask real nesting. The scan is a cheap first
    /// filter; CFPropertyList also refuses documents nested far beyond this limit.
    static func xmlDepth(_ bytes: [UInt8], limit: Int) -> Int? {
        var depth = 0
        var deepest = 0
        var index = 0
        while let open = bytes[index...].firstIndex(of: UInt8(ascii: "<")) {
            if let special = specialSpanEnd(bytes, at: open) {
                guard let end = special else { return nil }
                index = end
                continue
            }
            guard let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")) else { break }
            let tag = bytes[(open + 1)..<close]
            let closing = tag.first == UInt8(ascii: "/")
            let name = tag.drop { $0 == UInt8(ascii: "/") }.prefix { isNameByte($0) }
            if name.elementsEqual("array".utf8) || name.elementsEqual("dict".utf8) {
                if closing {
                    depth -= 1
                } else if tag.last != UInt8(ascii: "/") {
                    depth += 1
                    deepest = max(deepest, depth)
                    if depth > limit { return nil }
                }
            }
            index = close + 1
        }
        return deepest
    }

    /// For markup starting at `open` that is not an element tag: `.some(end)` with the index just past it, or
    /// `.some(nil)` when it is not terminated. Nil for an ordinary tag.
    private static func specialSpanEnd(_ bytes: [UInt8], at open: Int) -> Int?? {
        let rest = bytes[open...]
        for (start, terminator) in specialSpans where rest.starts(with: start) {
            return end(of: terminator, in: bytes, from: open + start.count)
        }
        guard rest.starts(with: Array("<!".utf8)) else { return nil }
        // A declaration such as `<!DOCTYPE ...>`; an internal subset `[...]` may contain `>`.
        guard let close = rest.firstIndex(of: UInt8(ascii: ">")) else { return .some(nil) }
        guard let bracket = rest.firstIndex(of: UInt8(ascii: "[")), bracket < close else { return close + 1 }
        return end(of: Array("]".utf8), in: bytes, from: bracket + 1).flatMap { after in
            bytes[after...].firstIndex(of: UInt8(ascii: ">")).map { $0 + 1 }
        }
    }

    private static let specialSpans: [(start: [UInt8], terminator: [UInt8])] = [
        (Array("<!--".utf8), Array("-->".utf8)),
        (Array("<![CDATA[".utf8), Array("]]>".utf8)),
        (Array("<?".utf8), Array("?>".utf8)),
    ]

    /// Index just past the first `terminator` at or after `start`, nil when there is none.
    private static func end(of terminator: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start <= bytes.count - terminator.count else { return nil }
        for candidate in start...(bytes.count - terminator.count)
        where bytes[candidate..<(candidate + terminator.count)].elementsEqual(terminator) {
            return candidate + terminator.count
        }
        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
    }
}

/// Walks the object graph of a binary property list (Apple's documented `bplist00` layout: objects, offset
/// table, 32-byte trailer) without recursion and reports whether the longest container path stays within the
/// limit. Malformed tables, out-of-range references and cycles are refused.
enum BinaryPlistNesting {
    private struct Layout {
        var offsetSize: Int
        var refSize: Int
        var objectCount: Int
        var topObject: Int
        var tableOffset: Int
    }

    private struct Frame {
        var object: Int
        var children: [Int]
        var next = 0
    }

    static func isWithinLimit(_ bytes: [UInt8], limit: Int) -> Bool {
        guard let layout = layout(of: bytes) else { return false }
        var height = [Int](repeating: -1, count: layout.objectCount)  // -1 unknown, -2 on the current path
        var stack: [Frame] = []
        guard let top = children(of: layout.topObject, in: bytes, layout: layout) else { return false }
        height[layout.topObject] = -2
        stack.append(Frame(object: layout.topObject, children: top))
        while var frame = stack.popLast() {
            guard frame.next < frame.children.count else {
                height[frame.object] = 1 + (frame.children.map { height[$0] }.max() ?? -1)
                continue
            }
            let child = frame.children[frame.next]
            frame.next += 1
            stack.append(frame)
            switch height[child] {
            case -2: return false  // cycle
            case -1:
                guard stack.count < limit, let grandChildren = children(of: child, in: bytes, layout: layout) else {
                    return false
                }
                height[child] = -2
                stack.append(Frame(object: child, children: grandChildren))
            case let known:
                if stack.count + known > limit { return false }
            }
        }
        return true
    }

    private static func layout(of bytes: [UInt8]) -> Layout? {
        guard bytes.count >= 8 + 32 else { return nil }
        let trailer = bytes.count - 32
        let offsetSize = Int(bytes[trailer + 6])
        let refSize = Int(bytes[trailer + 7])
        guard (1...8).contains(offsetSize), (1...8).contains(refSize),
            let count = readUInt(bytes, at: trailer + 8, size: 8), let top = readUInt(bytes, at: trailer + 16, size: 8),
            let table = readUInt(bytes, at: trailer + 24, size: 8),
            count > 0, count <= bytes.count, top < count, table >= 8, table + count * offsetSize <= trailer
        else { return nil }
        return Layout(offsetSize: offsetSize, refSize: refSize, objectCount: count, topObject: top, tableOffset: table)
    }

    /// Object references of a container (array, set, dict keys and values); empty for scalars; nil if malformed.
    private static func children(of object: Int, in bytes: [UInt8], layout: Layout) -> [Int]? {
        guard let start = readUInt(bytes, at: layout.tableOffset + object * layout.offsetSize, size: layout.offsetSize),
            start >= 8, start < layout.tableOffset
        else { return nil }
        let marker = bytes[start]
        let kind = marker >> 4
        guard kind == 0xA || kind == 0xC || kind == 0xD else { return [] }
        guard let (length, cursor) = containerLength(bytes, marker: marker, at: start + 1) else { return nil }
        let references = kind == 0xD ? length * 2 : length
        guard references <= layout.objectCount * 2, cursor + references * layout.refSize <= layout.tableOffset else {
            return nil
        }
        var result: [Int] = []
        result.reserveCapacity(references)
        for index in 0..<references {
            guard let reference = readUInt(bytes, at: cursor + index * layout.refSize, size: layout.refSize),
                reference < layout.objectCount
            else { return nil }
            result.append(reference)
        }
        return result
    }

    /// Length nibble, or a following integer object when the nibble is 0xF.
    private static func containerLength(_ bytes: [UInt8], marker: UInt8, at cursor: Int) -> (Int, Int)? {
        let nibble = Int(marker & 0x0F)
        guard nibble == 0x0F else { return (nibble, cursor) }
        guard cursor < bytes.count, bytes[cursor] >> 4 == 0x1 else { return nil }
        let size = 1 << Int(bytes[cursor] & 0x0F)
        guard size <= 8, let length = readUInt(bytes, at: cursor + 1, size: size) else { return nil }
        return (length, cursor + 1 + size)
    }

    /// Big-endian unsigned integer that fits in `Int`.
    private static func readUInt(_ bytes: [UInt8], at offset: Int, size: Int) -> Int? {
        guard offset >= 0, size > 0, offset + size <= bytes.count else { return nil }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + size)] { value = value << 8 | UInt64(byte) }
        return value <= UInt64(Int.max / 16) ? Int(value) : nil
    }
}
