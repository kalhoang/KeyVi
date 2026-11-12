// SPDX-License-Identifier: MPL-2.0

/// The result of parsing a letter string (spec 3.13): onset, vowel group, coda and remainder,
/// given as offsets from the start of the parsed letters.
package struct SyllableParse: Sendable, Hashable {
    package var onset: Onset
    /// Offset of the first letter of the vowel group (the length of the onset).
    package var vowelStart: Int
    /// Offset after the vowel group, where the consonant coda starts.
    package var codaStart: Int
    /// Offset after the coda, where the remainder starts.
    package var remainderStart: Int
    /// Number of parsed letters.
    package var count: Int

    package var vowelCount: Int { codaStart - vowelStart }
    package var hasVowelGroup: Bool { codaStart > vowelStart }
    package var hasCoda: Bool { remainderStart > codaStart }
    package var hasRemainder: Bool { count > remainderStart }

    /// 3.13 step 4: a non-empty vowel group and an empty remainder. Only such parses can be valid.
    package var isWellFormed: Bool { hasVowelGroup && !hasRemainder }

    /// Offsets of the vowel group.
    package var vowelRange: Range<Int> { vowelStart..<codaStart }
    /// Offsets of the rhyme (vowel group plus coda).
    package var rhymeRange: Range<Int> { vowelStart..<remainderStart }
}

/// The normative parse of spec 3.13. A pure function of the letters (ENG-R340): no keys, history or
/// configuration are involved.
package enum SyllableParser {
    /// Parses lowercase letters (tone marks are not part of `Letter`).
    package static func parse<C: RandomAccessCollection>(_ letters: C) -> SyllableParse where C.Element == Letter {
        let count = letters.count
        let start = letters.startIndex
        @inline(__always) func at(_ offset: Int) -> Letter { letters[letters.index(start, offsetBy: offset)] }

        // Step 1: onset.
        var onset = Onset.none
        var onsetLength = 0
        if count >= 2, at(0) == .q, at(1) == .u {
            onset = .qu
            onsetLength = 2
        } else if count >= 3, at(0) == .g, at(1) == .i, at(2).isVowel {
            // ENG-R305: `gi` is the onset only when a vowel letter follows; otherwise `g` + `i` (ENG-R306).
            onset = .gi
            onsetLength = 2
        } else if count >= 3, at(0) == .n, at(1) == .g, at(2) == .h {
            onset = .ngh  // longest match: `ngh` wins over `ng`
            onsetLength = 3
        } else if count >= 2, let pair = twoLetterOnset(at(0), at(1)) {
            onset = pair
            onsetLength = 2
        } else if count >= 1, let single = Onset.single(at(0)) {
            onset = single
            onsetLength = 1
        }

        // Step 2: the maximal run of vowel letters after the onset.
        var codaStart = onsetLength
        while codaStart < count, at(codaStart).isVowel { codaStart += 1 }
        // Step 3: the maximal run of consonant letters after the vowel group.
        var remainderStart = codaStart
        while remainderStart < count, at(remainderStart).isConsonant { remainderStart += 1 }

        return SyllableParse(
            onset: onset, vowelStart: onsetLength, codaStart: codaStart, remainderStart: remainderStart,
            count: count)
    }

    /// The multi-letter onsets of 3.13 step 1 (`bl br ch dr đr gh gl gr kh kl kr ng nh ph pl pr th
    /// tr`) plus `dz` from 3.3 (ENG-R316), indexed by `first.code * Letter.count + second.code`.
    private static let twoLetterTable: [Onset?] = {
        var table = [Onset?](repeating: nil, count: Letter.count * Letter.count)
        let onsets: [Onset] = [
            .bl, .br, .ch, .dr, .dStrokeR, .dz, .gh, .gl, .gr, .kh, .kl, .kr, .ng, .nh, .ph, .pl, .pr, .th, .tr,
        ]
        for onset in onsets {
            let letters = onset.letters
            table[Int(letters[0].code) * Letter.count + Int(letters[1].code)] = onset
        }
        return table
    }()

    @inline(__always)
    private static func twoLetterOnset(_ first: Letter, _ second: Letter) -> Onset? {
        twoLetterTable[Int(first.code) * Letter.count + Int(second.code)]
    }
}
