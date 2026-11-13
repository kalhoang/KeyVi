// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The independent oracle of ENG-T01: it spells the expected text of a syllable directly from its
/// onset, rhyme, tone and style using the rules of spec section 5, without calling any composition or
/// placement code of the engine. It works on `Character`s; the only engine data it reads is the raw
/// generated letter table (ENG-R301) to obtain precomposed code points.
public enum SyllableOracle {
    /// The case pattern of a spelled syllable.
    public enum Casing: Sendable, Hashable, CaseIterable {
        case lowercase
        /// First letter uppercase (`Việt`, `Đà`).
        case titlecase
        case uppercase
    }

    /// The display form (open `ươ` while typing, ENG-R531) or the committed form (ENG-R532).
    public enum Form: Sendable, Hashable, CaseIterable {
        /// What the token shows while typing: an open `uơ` is shown as `ươ` (ENG-R531).
        case display
        /// What a boundary commits in Vietnamese context: `uơ` (ENG-R532).
        case committed
    }

    private static let vowels: Set<Character> = ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"]
    private static let modifiedVowels: Set<Character> = ["ă", "â", "ê", "ô", "ơ", "ư"]
    /// The two-letter open groups whose tone position depends on the style (5.2).
    private static let styledPairs: Set<String> = ["oa", "oe", "uy"]

    /// The text of the syllable `onset` + `rhyme` (lowercase spellings as in spec 3.3 and 3.7 to
    /// 3.9) with `tone`, placed by the rules of 5.1 in `style`.
    public static func spell(
        onset: String, rhyme: String, tone: Tone, style: ToneStyle, casing: Casing = .lowercase,
        form: Form = .committed
    ) -> String {
        let rhymeLetters: [Character] = form == .display && rhyme == "uơ" ? ["ư", "ơ"] : Array(rhyme)
        let letters = Array(onset) + rhymeLetters
        let target = tone == .level ? nil : toneIndex(letters: letters, vowelStart: onset.count, style: style)
        var result = ""
        for (index, letter) in letters.enumerated() {
            let upper = casing == .uppercase || (casing == .titlecase && index == 0)
            result.unicodeScalars.append(glyph(letter, tone: index == target ? tone : .level, uppercase: upper))
        }
        return result
    }

    /// Spec 5.1. `vowelStart` is the length of the onset, so the `u` of `qu` and the `i` of a `gi`
    /// onset are never part of the vowel group.
    static func toneIndex(letters: [Character], vowelStart: Int, style: ToneStyle) -> Int? {
        var vowelEnd = vowelStart
        while vowelEnd < letters.count, vowels.contains(letters[vowelEnd]) { vowelEnd += 1 }
        let group = letters[vowelStart..<vowelEnd]
        guard !group.isEmpty else { return nil }
        if let last = group.indices.last(where: { modifiedVowels.contains(letters[$0]) }) { return last }  // rule 1
        if vowelEnd < letters.count { return vowelEnd - 1 }  // rule 2: consonant coda
        switch group.count {  // rule 3
        case 1: return vowelStart
        case 2: return styledPairs.contains(String(group)) && style == .modern ? vowelStart + 1 : vowelStart
        default: return vowelStart + 1
        }
    }

    private struct GlyphKey: Hashable {
        let letter: Character
        let tone: Tone
        let uppercase: Bool
    }

    /// Precomposed scalars for every (letter, tone, case) of the generated letter table, keyed by
    /// the lowercase letter as the spellings write it.
    private static let glyphs: [GlyphKey: Unicode.Scalar] = {
        let modified: [String: Character] = [
            "a breve": "ă", "a circumflex": "â", "e circumflex": "ê", "o circumflex": "ô", "o horn": "ơ",
            "u horn": "ư", "d stroke": "đ",
        ]
        var table: [GlyphKey: Unicode.Scalar] = [:]
        for entry in LetterTable.entries {
            let letter = entry.modifier == .none ? Character(entry.base) : modified["\(entry.base) \(entry.modifier)"]!
            table[GlyphKey(letter: letter, tone: entry.tone, uppercase: entry.isUppercase)] = entry.scalar
        }
        return table
    }()

    private static func glyph(_ letter: Character, tone: Tone, uppercase: Bool) -> Unicode.Scalar {
        if let scalar = glyphs[GlyphKey(letter: letter, tone: tone, uppercase: uppercase)] { return scalar }
        // Consonants are plain ASCII and carry no tone.
        let ascii = letter.unicodeScalars.first!.value
        precondition(tone == .level && letter.isASCII, "oracle cannot spell \(letter) with \(tone)")
        return Unicode.Scalar(uppercase && ascii >= 97 && ascii <= 122 ? ascii - 32 : ascii)!
    }
}
