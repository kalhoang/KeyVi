// SPDX-License-Identifier: MPL-2.0

/// The macro matching window of ENG-R1102 at a boundary key.
///
/// The span is the raw characters typed since the last whitespace, Return, Tab or reset: the raw keys of
/// the committed tokens of the run and of the active token, and the boundary characters between them.
/// History is cleared by Return, Tab and reset, so the span starts at the last whitespace boundary of the
/// history or at its start. It is built only when it can match: at most 32 characters, all printable
/// ASCII (triggers are, ENG-R1101), no macro expansion inside (an expansion is never expanded again,
/// docs/decisions/0103-engine-commit-history-macros.md) and a known start (`History.startsMidSpan`).
/// The cost is bounded by the 32-character cap, whatever the history or table size (ENG-R1105).
package struct MacroSpan: Sendable, Hashable {
    /// The span as typed, case preserved: the raw keys of the expansion's history token (ENG-R1104) and
    /// the input of adaptive casing.
    package let typed: [UInt8]
    /// The lowercased lookup key.
    package let key: MacroKey
    /// How many history entries (newest first) the span covers, besides the active token.
    package let historyEntryCount: Int

    package init?(active: ActiveToken?, history: History) {
        var length = 0
        if let active {
            if active.isMacro { return nil }
            length = active.composition.raw.count
            guard length <= MacroKey.capacity else { return nil }
        }
        // Walk back to the start of the span without copying anything.
        let entries = history.entries
        var start = entries.endIndex
        var reachedWhitespace = false
        while start > entries.startIndex {
            switch entries[start - 1] {
            case .boundary(let character):
                if character.isWhitespace {
                    reachedWhitespace = true
                } else {
                    guard character.asciiValue != nil else { return nil }
                    length += 1
                }
            case .token(let committed):
                if committed.token.isMacro { return nil }
                length += committed.token.composition.raw.count
            }
            if reachedWhitespace { break }
            guard length <= MacroKey.capacity else { return nil }
            start -= 1
        }
        guard length > 0, reachedWhitespace || !history.startsMidSpan else { return nil }
        // Copy the span forwards.
        var typed: [UInt8] = []
        typed.reserveCapacity(length)
        for entry in entries[start...] {
            switch entry {
            case .boundary(let character): if let byte = character.asciiValue { typed.append(byte) }
            case .token(let committed): typed.append(contentsOf: committed.token.composition.raw)
            }
        }
        if let active { typed.append(contentsOf: active.composition.raw) }
        guard let key = MacroKey(lowercasing: typed) else { return nil }
        self.typed = typed
        self.key = key
        historyEntryCount = entries.endIndex - start
    }
}
