// SPDX-License-Identifier: MPL-2.0

/// Tone placement (spec 5.1, 5.2) as a pure function of the current letters. It is evaluated on
/// every key and the position is never stored (ENG-R501), so the tone moves when the syllable grows
/// or shrinks (5.4).
package enum TonePlacement {
    /// The offset of the letter that carries the tone, or nil when the vowel group is empty (a tone
    /// key then does not apply, ENG-R410). The vowel group excludes the `u` of `qu` and the `i` of a
    /// `gi` onset, which makes both styles agree after those onsets (ENG-R502).
    package static func toneOffset<C: RandomAccessCollection>(in letters: C, parse: SyllableParse, style: ToneStyle) -> Int?
    where C.Element == Letter {
        guard parse.hasVowelGroup else { return nil }
        let start = letters.startIndex
        @inline(__always) func at(_ offset: Int) -> Letter { letters[letters.index(start, offsetBy: offset)] }

        // Rule 1: the last letter with a modifier (ă â ê ô ơ ư).
        var offset = parse.codaStart - 1
        while offset >= parse.vowelStart {
            if at(offset).isModifiedVowel { return offset }
            offset -= 1
        }
        // Rule 2: a consonant coda puts the tone on the last letter of the vowel group.
        if parse.hasCoda { return parse.codaStart - 1 }
        // Rule 3: open or semivowel ending.
        let first = parse.vowelStart
        switch parse.vowelCount {
        case 1:
            return first
        case 2:
            // 5.2: `oa`, `oe`, `uy` are the only pairs whose placement depends on the style.
            let pair = (at(first), at(first + 1))
            let isGlidePair = pair == (.o, .a) || pair == (.o, .e) || pair == (.u, .y)
            return isGlidePair && style == .modern ? first + 1 : first
        default:
            // Three letters: the middle one. Four or more (never valid): the second, so the result is
            // still deterministic.
            return first + 1
        }
    }

    /// Convenience: parse, then place.
    package static func toneOffset(in letters: [Letter], style: ToneStyle) -> Int? {
        toneOffset(in: letters, parse: SyllableParser.parse(letters), style: style)
    }
}
