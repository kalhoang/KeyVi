// SPDX-License-Identifier: MPL-2.0
//
// Text utilities for building the attested-syllable list and the prose corpus
// (spec/01-engine.md 8.2 and 13.4). The letter inventory comes from spec/01-engine.md 3.2:
// 12 vowel letters with six tones, the Tier A consonants and the Tier B onset `z`.

import Foundation

enum VietnameseText {
    /// Base vowel letters (spec/01-engine.md 3.2).
    static let baseVowels: [Character] = ["a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "y"]

    /// Combining marks for tones 1...5 (sắc, huyền, hỏi, ngã, nặng).
    static let toneMarks: [Character] = ["\u{0301}", "\u{0300}", "\u{0309}", "\u{0303}", "\u{0323}"]

    /// Consonant letters of Tier A plus `z` (Tier B onset). `f`, `j` and `w` are not Vietnamese letters.
    static let consonants: Set<Character> = [
        "b", "c", "d", "đ", "g", "h", "k", "l", "m", "n", "p", "q", "r", "s", "t", "v", "x", "z",
    ]

    /// Lowercase vowel letter (any tone) -> (base vowel, tone 0...5).
    static let vowelTable: [Character: (base: Character, tone: Int)] = {
        var table: [Character: (base: Character, tone: Int)] = [:]
        for base in baseVowels {
            table[base] = (base, 0)
            for (index, mark) in toneMarks.enumerated() {
                let composed = Character(String([base, mark]).precomposedStringWithCanonicalMapping)
                table[composed] = (base, index + 1)
            }
        }
        return table
    }()

    /// (base vowel, tone) -> precomposed lowercase letter.
    static func vowel(_ base: Character, tone: Int) -> Character {
        guard tone > 0 else { return base }
        return Character(String([base, toneMarks[tone - 1]]).precomposedStringWithCanonicalMapping)
    }

    static func isVietnameseLetter(_ character: Character) -> Bool {
        consonants.contains(character) || vowelTable[character] != nil
    }

    /// NFC form (ENG-R102: output uses precomposed letters only).
    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// Splits `text` into maximal runs of letters (`Character.isLetter`). Everything else is a boundary.
    static func letterRuns(_ text: String) -> [Substring] {
        text.split(whereSeparator: { !$0.isLetter })
    }

    /// Tokeniser for the attested-syllable list: NFC, lowercase, split on non-letters, keep tokens made
    /// only of Vietnamese letters.
    static func syllableTokens(_ text: String) -> [String] {
        letterRuns(nfc(text).lowercased()).compactMap { run in
            run.allSatisfy(isVietnameseLetter) ? String(run) : nil
        }
    }

    /// Tokeniser for the prose corpus: as `syllableTokens` but keeps the original case.
    static func proseTokens(_ text: String) -> [String] {
        letterRuns(nfc(text)).compactMap { run in
            let word = String(run)
            return word.lowercased().allSatisfy(isVietnameseLetter) ? word : nil
        }
    }

    /// The other tone placement of an open `oa`, `oe` or `uy` syllable (spec/01-engine.md 5.2):
    /// `hòa` <-> `hoà`, `khỏe` <-> `khoẻ`, `thủy` <-> `thuỷ`. Returns nil when both styles agree,
    /// including after a `qu` onset (ENG-R502).
    static func otherToneStyle(of syllable: String) -> String? {
        var letters = Array(syllable)
        guard letters.count >= 2 else { return nil }
        let last = letters.count - 1
        guard let second = vowelTable[letters[last]], let first = vowelTable[letters[last - 1]] else { return nil }
        let pair = String([first.base, second.base])
        guard ["oa", "oe", "uy"].contains(pair) else { return nil }
        if last >= 2 {
            let before = letters[last - 2]
            // The pair must be the whole vowel group: preceded by a consonant other than the `q` of `qu`.
            guard consonants.contains(before), before != "q" else { return nil }
        }
        let tone = max(first.tone, second.tone)
        guard tone > 0, first.tone == 0 || second.tone == 0 else { return nil }
        if first.tone > 0 {
            letters[last - 1] = first.base
            letters[last] = vowel(second.base, tone: tone)
        } else {
            letters[last - 1] = vowel(first.base, tone: tone)
            letters[last] = second.base
        }
        return String(letters)
    }
}
