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
        var offset = parse.vowelStart
        while offset + 1 < parse.codaStart {
            let first = result[offset]
            let second = result[offset + 1]
            let isPair = (first == .u || first == .uHorn) && (second == .o || second == .oHorn)
            if isPair, first == .uHorn || second == .oHorn {
                result[offset] = .uHorn
                result[offset + 1] = .oHorn
            }
            offset += 1
        }
        return result
    }

    /// Convenience: parse, then complete horns.
    package static func display(_ letters: [Letter]) -> [Letter] {
        display(letters, parse: SyllableParser.parse(letters))
    }

    /// ENG-R532: at commit an open `ươ` (vowel group exactly `ươ`, no coda, nothing after) is written
    /// `uơ` (`thươ` -> `thuơ`, displayed with the tone on `ơ`). Other letters are returned unchanged.
    package static func committed(_ letters: [Letter], parse: SyllableParse) -> [Letter] {
        guard parse.vowelCount == 2, !parse.hasCoda, !parse.hasRemainder,
            letters[parse.vowelStart] == .uHorn, letters[parse.vowelStart + 1] == .oHorn
        else { return letters }
        var result = letters
        result[parse.vowelStart] = .u
        return result
    }
}
