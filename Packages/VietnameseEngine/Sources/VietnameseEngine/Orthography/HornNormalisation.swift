// SPDX-License-Identifier: MPL-2.0

/// Horn handling for a `u o` pair (spec 5.5).
package enum HornNormalisation {
    /// ENG-R530, ENG-R531: within a `u o` pair of the vowel group, a horn on either letter means a
    /// horn on both in the display (`tuwong`, `tuowng` -> `tương`; an open pair shows as `ươ`). An `o`
    /// with a circumflex keeps it (ENG-R533 governs how a circumflex and horns replace each other).
    /// The `u` of `qu` is never part of such a pair: it belongs to the onset, not the vowel group.
    /// Returns the letters unchanged (no copy) when there is nothing to complete.
    package static func display(_ letters: [Letter], parse: SyllableParse) -> [Letter] {
        guard parse.vowelCount >= 2 else { return letters }
        var result = letters
        for offset in parse.vowelRange {
            result[offset] = displayLetter(at: offset, in: letters, parse: parse)
        }
        return result
    }

    /// Convenience: parse, then complete horns.
    package static func display(_ letters: [Letter]) -> [Letter] {
        display(letters, parse: SyllableParser.parse(letters))
    }

    /// The display form of the letter at `offset` (ENG-R530), computed locally so that composition
    /// can render and check viability without building a normalised copy (ENG-R1230).
    ///
    /// A `u o` pair is a `u` or `ư` followed by an `o` or `ơ` inside the vowel group. A letter cannot be
    /// the second letter of one pair and the first of another (it would have to be both `o` and `u`),
    /// so looking at the two neighbours is exact.
    @inline(__always)
    package static func displayLetter<C: RandomAccessCollection>(at offset: Int, in letters: C, parse: SyllableParse)
        -> Letter
    where C.Element == Letter, C.Index == Int {
        let letter = letters[letters.startIndex + offset]
        guard offset >= parse.vowelStart, offset < parse.codaStart else { return letter }
        if letter == .u, offset + 1 < parse.codaStart, letters[letters.startIndex + offset + 1] == .oHorn {
            return .uHorn
        }
        if letter == .o, offset > parse.vowelStart, letters[letters.startIndex + offset - 1] == .uHorn {
            return .oHorn
        }
        return letter
    }

    /// ENG-R532: at commit an open `ươ` (vowel group exactly `ươ`, no coda, nothing after) is written
    /// `uơ` (`thươ` -> `thuơ`, displayed with the tone on `ơ`). Other letters are returned unchanged.
    package static func committed(_ letters: [Letter], parse: SyllableParse) -> [Letter] {
        guard isOpenHornPair(letters, parse: parse) else { return letters }
        var result = letters
        result[parse.vowelStart] = .u
        return result
    }

    /// Whether the display letters have the open `ươ` of ENG-R532: vowel group exactly `ươ`, no coda,
    /// no remainder.
    package static func isOpenHornPair<C: RandomAccessCollection>(_ letters: C, parse: SyllableParse) -> Bool
    where C.Element == Letter, C.Index == Int {
        guard parse.vowelCount == 2, !parse.hasCoda, !parse.hasRemainder else { return false }
        let start = letters.startIndex + parse.vowelStart
        return letters[start] == .uHorn && letters[start + 1] == .oHorn
    }
}
