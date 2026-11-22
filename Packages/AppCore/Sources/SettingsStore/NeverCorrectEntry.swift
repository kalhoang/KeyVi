// SPDX-License-Identifier: GPL-3.0-or-later
//
// An entry of the never-correct list (03-product.md PRD-R81, spec/01-engine.md ENG-R1118, 1.1.0): a typed word the
// typo correction leaves alone. The engine compares it with the lowercased typed word, which is ASCII letters only
// (ENG-R1111), so an entry is lowercase `a` to `z`; anything else is refused with an explanation in Settings. One
// rule for the three ways in: the field in Settings, the restore key (`LearningSignal.neverCorrect`) and an import.

/// Validation of never-correct entries.
public enum NeverCorrectEntry {
    /// The longest entry accepted, in letters. The engine corrects words of at most 24 letters (ENG-R1111); the
    /// margin keeps a pasted long word refusable without truncating it.
    public static let maximumLength = 64

    /// `text` with surrounding whitespace removed and lowercased, when it is 1 to `maximumLength` ASCII letters;
    /// nil otherwise (digits, marks, spaces inside, punctuation, an empty or too long word).
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
        let lowered = String(trimmed).lowercased()
        let letters = lowered.utf8
        guard (1...maximumLength).contains(letters.count),
            letters.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) })
        else { return nil }
        return lowered
    }
}
