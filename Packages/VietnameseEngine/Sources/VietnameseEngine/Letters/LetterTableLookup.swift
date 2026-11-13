// SPDX-License-Identifier: MPL-2.0

/// One emittable letter of the generated table (ENG-R301).
package struct LetterTableEntry: Sendable, Hashable {
    /// The precomposed code point (ENG-R102: the engine never emits combining marks).
    package let scalarValue: UInt32
    /// The unmodified lowercase ASCII base (`"d"` for `đ`).
    package let base: Unicode.Scalar
    package let modifier: LetterModifier
    package let tone: Tone
    package let isUppercase: Bool

    package init(
        _ scalarValue: UInt32, _ base: Unicode.Scalar, _ modifier: LetterModifier, _ tone: Tone, uppercase: Bool
    ) {
        self.scalarValue = scalarValue
        self.base = base
        self.modifier = modifier
        self.tone = tone
        self.isUppercase = uppercase
    }

    /// The letter identity of this entry.
    package var letter: Letter {
        Letter(asciiLowercase: UInt8(base.value))!.applying(modifier)!
    }

    package var scalar: Unicode.Scalar { Unicode.Scalar(scalarValue)! }
}

/// A decoded character: letter identity, tone and case.
package struct Glyph: Sendable, Hashable {
    package let letter: Letter
    package let tone: Tone
    package let isUppercase: Bool

    package init(letter: Letter, tone: Tone, isUppercase: Bool) {
        self.letter = letter
        self.tone = tone
        self.isUppercase = isUppercase
    }
}

/// Lookups derived from the generated `entries` (Generated/LetterTable.swift) plus the ASCII
/// consonants. All tables are immutable (ENG-R1202).
package enum LetterTable {
    /// Scalar value for (letter, tone, case), indexed by `(code * 6 + tone) * 2 + upper`.
    /// Zero marks a combination that does not exist (a tone on a consonant).
    private static let encodeTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: Letter.count * 6 * 2)
        // ASCII letters without tone, lowercase and uppercase.
        for letter in Letter.all where letter.modifier == .none {
            let ascii = UInt32(letter.baseASCII)
            table[index(letter, .level, false)] = ascii
            table[index(letter, .level, true)] = ascii - 32
        }
        for entry in entries {
            table[index(entry.letter, entry.tone, entry.isUppercase)] = entry.scalarValue
        }
        return table
    }()

    /// Every scalar the engine understands as a letter (ASCII letters and the 146 table letters).
    private static let decodeTable: [UInt32: Glyph] = {
        var table: [UInt32: Glyph] = [:]
        for letter in Letter.all {
            for tone in Tone.allTones {
                for upper in [false, true] {
                    let value = encodeTable[index(letter, tone, upper)]
                    if value != 0 { table[value] = Glyph(letter: letter, tone: tone, isUppercase: upper) }
                }
            }
        }
        return table
    }()

    @inline(__always)
    private static func index(_ letter: Letter, _ tone: Tone, _ uppercase: Bool) -> Int {
        (Int(letter.code) * 6 + tone.rawValue) * 2 + (uppercase ? 1 : 0)
    }

    /// The scalar the engine emits for `letter` with `tone` in the given case. A tone on a
    /// consonant is ignored (never produced by the rules: tones only go on vowel letters).
    @inline(__always)
    package static func scalar(_ letter: Letter, tone: Tone, uppercase: Bool) -> Unicode.Scalar {
        var value = encodeTable[index(letter, tone, uppercase)]
        if value == 0 { value = encodeTable[index(letter, .level, uppercase)] }
        return Unicode.Scalar(value).unsafelyUnwrapped
    }

    /// Whether `letter` can carry `tone` (true for every vowel letter, false for a consonant with a tone).
    package static func canCarry(_ letter: Letter, tone: Tone) -> Bool {
        encodeTable[index(letter, tone, false)] != 0
    }

    /// Decodes one precomposed scalar into letter, tone and case; nil if it is not one of the
    /// 52 ASCII letters or the 146 table letters.
    package static func glyph(for scalar: Unicode.Scalar) -> Glyph? {
        decodeTable[scalar.value]
    }
}

extension Tone {
    /// The six tones in spec order (0 ngang ... 5 nặng).
    package static let allTones: [Tone] = [.level, .acute, .grave, .hook, .tilde, .dot]
}
