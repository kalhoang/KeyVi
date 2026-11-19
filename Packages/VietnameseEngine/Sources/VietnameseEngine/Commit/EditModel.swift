// SPDX-License-Identifier: MPL-2.0
//
// The edit model of the typo correction, spec 11A.2: the words at distance one from a typed word (ENG-R1113, with
// its position rules, for the English fits) and every single edit without them (ENG-R1125, for the Vietnamese
// check). The edits are written into a 32-byte scratch on the stack (`withUnsafeTemporaryAllocation`) and handed to
// the caller one at a time, so an enumeration allocates nothing and costs time proportional to the word's length
// (ENG-R1122). The model is a plain value holding the neighbours table only (ENG-R1202, ENG-R1203).

/// The four edits of ENG-R1113 over lowercase ASCII bytes: transposition of two neighbouring letters, deletion,
/// insertion of a letter `a` to `z`, substitution by a neighbouring key of the bundled QWERTY table.
package struct EditModel: Sendable {
    /// The longest word the model edits: an insertion adds one byte to the 32-byte scratch.
    package static let maximumLength = 31

    /// The bytes of one neighbours row: the count, then up to seven neighbours.
    private static let rowWidth = 8
    private static let scratchCapacity = 32
    private static let a = UInt8(ascii: "a")
    private static let z = UInt8(ascii: "z")

    /// 26 rows of `rowWidth` bytes, row `letter - a`: the number of neighbours, then the neighbours.
    private let neighbourRows: [UInt8]

    /// A model over `neighbours` (lowercase letter: its neighbouring keys, ENG-R1113). Entries for other
    /// characters and neighbours that are not lowercase letters are ignored; a letter without an entry has no
    /// substitution edit (empty correction data, `CorrectionData.empty`).
    package init(neighbours: [Character: String]) {
        var rows = [UInt8](repeating: 0, count: 26 * Self.rowWidth)
        for (key, value) in neighbours {
            guard let byte = key.asciiValue, ASCII.isLowercaseLetter(byte) else { continue }
            let row = Int(byte - Self.a) * Self.rowWidth
            var count = 0
            for neighbour in value.utf8 where ASCII.isLowercaseLetter(neighbour) && count < Self.rowWidth - 1 {
                count += 1
                rows[row + count] = neighbour
            }
            rows[row] = UInt8(count)
        }
        neighbourRows = rows
    }

    /// Calls `body` with every word at distance one from `word` (lowercase ASCII bytes), in the order
    /// transpositions, deletions, insertions, substitutions; stops as soon as `body` returns false. A word reached by
    /// several edits is passed once per edit (the caller keeps the distinct words, ENG-R1114). With `positionRules`
    /// (ENG-R1113) the first letter is deleted only when it equals the second, the last only when it equals the one
    /// before it, a letter is inserted after the last only when it repeats it, and a last `r` after `e` is never
    /// replaced by `d`; without them (ENG-R1125) every edit is enumerated. The buffer passed to `body` is valid only
    /// during the call. An empty word or one longer than `maximumLength` has no edits.
    package func forEachEdit(
        of word: UnsafeBufferPointer<UInt8>, positionRules: Bool, _ body: (UnsafeBufferPointer<UInt8>) -> Bool
    ) {
        guard let source = word.baseAddress, !word.isEmpty, word.count <= Self.maximumLength else { return }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.scratchCapacity) { scratch in
            guard let target = scratch.baseAddress else { return }
            let edit = Edit(source: source, count: word.count, target: target, positionRules: positionRules)
            _ =
                edit.transpositions(body) && edit.deletions(body) && edit.insertions(body)
                && edit.substitutions(neighbourRows, body)
        }
    }

    /// One enumeration: the word and the scratch it writes into.
    private struct Edit {
        let source: UnsafePointer<UInt8>
        let count: Int
        let target: UnsafeMutablePointer<UInt8>
        let positionRules: Bool

        /// Two neighbouring letters swapped; equal letters are skipped (the swap gives the word itself).
        func transpositions(_ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
            target.update(from: source, count: count)
            var index = 0
            while index + 1 < count {
                let first = target[index]
                let second = target[index + 1]
                if first != second {
                    target[index] = second
                    target[index + 1] = first
                    let goOn = body(UnsafeBufferPointer(start: target, count: count))
                    target[index] = first
                    target[index + 1] = second
                    if !goOn { return false }
                }
                index += 1
            }
            return true
        }

        /// One letter deleted; with the position rules the first and last letters only when doubled.
        func deletions(_ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
            guard count > 1 else { return true }
            var index = 0
            while index < count {
                if !positionRules || isDeletable(index) {
                    target.update(from: source, count: index)
                    (target + index).update(from: source + index + 1, count: count - index - 1)
                    if !body(UnsafeBufferPointer(start: target, count: count - 1)) { return false }
                }
                index += 1
            }
            return true
        }

        private func isDeletable(_ index: Int) -> Bool {
            if index == 0 { return source[0] == source[1] }
            if index == count - 1 { return source[index] == source[index - 1] }
            return true
        }

        /// One letter `a` to `z` inserted; with the position rules after the last letter only when it repeats it.
        func insertions(_ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
            var position = 0
            while position <= count {
                target.update(from: source, count: position)
                (target + position + 1).update(from: source + position, count: count - position)
                let edited = UnsafeBufferPointer(start: target, count: count + 1)
                if positionRules, position == count {
                    target[position] = source[count - 1]
                    if !body(edited) { return false }
                } else {
                    var letter = EditModel.a
                    while letter <= EditModel.z {
                        target[position] = letter
                        if !body(edited) { return false }
                        letter += 1
                    }
                }
                position += 1
            }
            return true
        }

        /// One letter replaced by a neighbouring key; with the position rules never a last `r` after `e` by `d`.
        func substitutions(_ rows: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
            target.update(from: source, count: count)
            let edited = UnsafeBufferPointer(start: target, count: count)
            var index = 0
            while index < count {
                let original = source[index]
                if ASCII.isLowercaseLetter(original) {
                    let row = Int(original - EditModel.a) * EditModel.rowWidth
                    let neighbours = Int(rows[row])
                    let keepsParticiple =
                        positionRules && index == count - 1 && index > 0
                        && original == UInt8(ascii: "r") && source[index - 1] == UInt8(ascii: "e")
                    var slot = 1
                    while slot <= neighbours {
                        let neighbour = rows[row + slot]
                        if !(keepsParticiple && neighbour == UInt8(ascii: "d")) {
                            target[index] = neighbour
                            if !body(edited) { return false }
                        }
                        slot += 1
                    }
                    target[index] = original
                }
                index += 1
            }
            return true
        }
    }
}
