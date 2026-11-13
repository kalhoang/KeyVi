// SPDX-License-Identifier: MPL-2.0

/// What the rules of 8.1 and the language rule of ENG-R823 need to know about a committed display `C`,
/// computed in one pass over its scalars (ENG-R1232: proportional to the token length).
package struct CommittedTextFacts: Sendable, Hashable {
    /// `C` contains a vowel letter (`a ă â e ê i o ô ơ u ư y`, any tone, any case). Rule L3.
    package private(set) var hasVowel = false
    /// `C` contains `ă â đ ê ô ơ ư` or a toned vowel, in either case (ENG-R823).
    package private(set) var hasVietnameseOnlyLetter = false
    /// Every scalar of `C` is ASCII.
    package private(set) var isASCII = true
    /// The tier of `C` as one syllable (3.12, 3.13); `.invalid` when `C` contains anything but letters
    /// of the engine's alphabet, more than one tone mark, or does not parse.
    package private(set) var validity = Validity.invalid
    /// `C` in lowercase (ASCII letters folded, Vietnamese letters through the letter table, ENG-R905),
    /// for the lexicon (L4) and attested-syllable (L8) lookups.
    package private(set) var lowercased = ""

    /// No syllable has more letters (`ngh` + a four-letter rhyme such as `iêng`, 3.3 and 3.7): a longer
    /// text is invalid without a parse.
    package static let maximumSyllableLetters = 8

    package init(_ text: String) {
        var letters: [Letter] = []
        letters.reserveCapacity(Self.maximumSyllableLetters + 1)
        var tone = Tone.level
        var toneCount = 0
        var onlyLetters = true
        // The lowercase form is collected as UTF-8 bytes and turned into a string once (long literal
        // tokens, REG-02); lowercase letters have the same UTF-8 length as their capitals.
        var lowercaseBytes: [UInt8] = []
        lowercaseBytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            guard let glyph = Self.glyph(scalar) else {
                onlyLetters = false
                if scalar.value >= 0x80 { isASCII = false }
                UTF8.encode(scalar) { lowercaseBytes.append($0) }
                continue
            }
            if scalar.value >= 0x80 {
                isASCII = false
                hasVietnameseOnlyLetter = true
            }
            if glyph.letter.isVowel { hasVowel = true }
            if glyph.tone != .level {
                tone = glyph.tone
                toneCount += 1
            }
            if letters.count <= Self.maximumSyllableLetters { letters.append(glyph.letter) }
            UTF8.encode(LetterTable.scalar(glyph.letter, tone: glyph.tone, uppercase: false)) {
                lowercaseBytes.append($0)
            }
        }
        lowercased = String(decoding: lowercaseBytes, as: UTF8.self)
        if onlyLetters, toneCount <= 1, !letters.isEmpty, letters.count <= Self.maximumSyllableLetters {
            validity = SyllableTables.validity(of: letters, tone: tone)
        }
    }

    /// ASCII letters without a dictionary lookup; other scalars through the generated letter table.
    @inline(__always)
    private static func glyph(_ scalar: Unicode.Scalar) -> Glyph? {
        let value = scalar.value
        if value < 0x80 {
            let byte = UInt8(value)
            guard let letter = Letter(ascii: byte) else { return nil }
            return Glyph(letter: letter, tone: .level, isUppercase: ASCII.isUppercaseLetter(byte))
        }
        return LetterTable.glyph(for: scalar)
    }
}
