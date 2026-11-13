// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Prefix trimming of an edit (PLT-R402) and Unicode chunking of an insertion (PLT-R404, PLT-R480). Pure
// functions on the inject thread; never on the tap (they allocate).

internal import RealtimeSupport

/// An edit after common-prefix trimming. `deleteUTF16Count` follows the trimmed deletion: recomputed from the
/// replaced text when a prefix was trimmed, otherwise the engine's value is kept (ENG-R630).
struct MinimalEdit: Sendable, Hashable {
    var deleteCount: Int
    var deleteUTF16Count: Int
    var insertion: String

    /// PLT-R402. `replaced` is the text expected before the caret (the whole active token or just the deleted
    /// part); only its last `deleteCount` graphemes are compared. Graphemes compare by canonical equivalence,
    /// so a kept prefix always looks the same as the text it stands for.
    init(deleteCount: Int, deleteUTF16Count: Int, replaced: String?, insertion: String) {
        self.deleteCount = deleteCount
        self.deleteUTF16Count = deleteUTF16Count
        self.insertion = insertion
        guard let replaced, deleteCount > 0, !insertion.isEmpty else { return }
        let replacedGraphemes = Array(replaced)
        guard replacedGraphemes.count >= deleteCount else { return }
        let deleted = replacedGraphemes.suffix(deleteCount)
        var common = 0
        for (old, new) in zip(deleted, insertion) {
            guard old == new else { break }
            common += 1
        }
        guard common > 0 else { return }
        let remaining = deleted.dropFirst(common)
        self.deleteCount = remaining.count
        self.deleteUTF16Count = remaining.reduce(0) { $0 + $1.utf16.count }
        self.insertion = String(insertion.dropFirst(common))
    }

    var isEmpty: Bool { deleteCount == 0 && insertion.isEmpty }
}

/// PLT-R404, PLT-R480.
enum GraphemeChunking {
    /// Hard limit of one synthetic event (`CGEventKeyboardSetUnicodeString`, PLT-R404).
    static let eventLimit = InlineUTF16.capacity

    /// One grapheme per chunk, or as many whole graphemes as fit into `maxUTF16` units (clamped to 1...20). A
    /// grapheme longer than the cap goes alone; one longer than 20 units (never Vietnamese) is split at Unicode
    /// scalar boundaries, because dropping text is worse than splitting a pathological cluster.
    static func chunks(of text: String, maxUTF16: Int, oneGraphemePerEvent: Bool) -> [InlineUTF16] {
        let cap = max(1, min(maxUTF16, eventLimit))
        var result: [InlineUTF16] = []
        var pending = ""
        var pendingUnits = 0
        for grapheme in text {
            let units = grapheme.utf16.count
            if !oneGraphemePerEvent, pendingUnits + units <= cap {
                pending.append(grapheme)
                pendingUnits += units
                continue
            }
            flush(&pending, &pendingUnits, into: &result)
            if units > eventLimit {
                result.append(contentsOf: scalarPieces(of: grapheme))
            } else if oneGraphemePerEvent || units > cap {
                result.append(inline(String(grapheme)))
            } else {
                pending = String(grapheme)
                pendingUnits = units
            }
        }
        flush(&pending, &pendingUnits, into: &result)
        return result
    }

    private static func flush(_ pending: inout String, _ units: inout Int, into result: inout [InlineUTF16]) {
        guard units > 0 else { return }
        result.append(inline(pending))
        pending = ""
        units = 0
    }

    private static func scalarPieces(of grapheme: Character) -> [InlineUTF16] {
        var pieces: [InlineUTF16] = []
        var piece = String.UnicodeScalarView()
        var units = 0
        for scalar in grapheme.unicodeScalars {
            let width = UTF16.width(scalar)
            if units + width > eventLimit {
                pieces.append(inline(String(piece)))
                piece = String.UnicodeScalarView()
                units = 0
            }
            piece.append(scalar)
            units += width
        }
        if units > 0 { pieces.append(inline(String(piece))) }
        return pieces
    }

    /// Callers guarantee at most 20 units.
    private static func inline(_ text: String) -> InlineUTF16 {
        guard let value = InlineUTF16(text) else { preconditionFailure("chunk exceeds the event limit") }
        return value
    }
}
