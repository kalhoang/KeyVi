// SPDX-License-Identifier: MPL-2.0

/// A vowel modifier or the d stroke (spec 3.2).
package enum LetterModifier: UInt8, Sendable, Hashable, CaseIterable {
    case none, breve, circumflex, horn, stroke
}

/// The lowercase identity of one letter of the engine's alphabet: the 26 ASCII letters plus the
/// seven Vietnamese letters that carry a modifier or the stroke (ă â đ ê ô ơ ư), 33 in total.
///
/// Case and tone are not part of the identity: composition keeps them next to the letter and the
/// letter table (ENG-R301) turns (letter, tone, case) into the emitted scalar. The code is a dense
/// index so that per-key tables (viability automaton, rhyme keys) are flat arrays (ENG-R1230).
package struct Letter: Hashable, Sendable, Comparable, CustomStringConvertible {
    package let code: UInt8

    /// Number of distinct letters; codes are `0..<count`.
    package static let count = 33

    @inline(__always)
    package init(code: UInt8) {
        precondition(Int(code) < Letter.count, "letter code out of range")
        self.code = code
    }

    package static func < (lhs: Letter, rhs: Letter) -> Bool { lhs.code < rhs.code }

    // Codes follow the Vietnamese alphabet (a ă â b c d đ e ê ... u ư v x y) with the four letters
    // that Vietnamese spelling does not use (f j w z) at their ASCII positions.
    package static let a = Letter(code: 0)
    package static let aBreve = Letter(code: 1)
    package static let aCircumflex = Letter(code: 2)
    package static let b = Letter(code: 3)
    package static let c = Letter(code: 4)
    package static let d = Letter(code: 5)
    package static let dStroke = Letter(code: 6)
    package static let e = Letter(code: 7)
    package static let eCircumflex = Letter(code: 8)
    package static let f = Letter(code: 9)
    package static let g = Letter(code: 10)
    package static let h = Letter(code: 11)
    package static let i = Letter(code: 12)
    package static let j = Letter(code: 13)
    package static let k = Letter(code: 14)
    package static let l = Letter(code: 15)
    package static let m = Letter(code: 16)
    package static let n = Letter(code: 17)
    package static let o = Letter(code: 18)
    package static let oCircumflex = Letter(code: 19)
    package static let oHorn = Letter(code: 20)
    package static let p = Letter(code: 21)
    package static let q = Letter(code: 22)
    package static let r = Letter(code: 23)
    package static let s = Letter(code: 24)
    package static let t = Letter(code: 25)
    package static let u = Letter(code: 26)
    package static let uHorn = Letter(code: 27)
    package static let v = Letter(code: 28)
    package static let w = Letter(code: 29)
    package static let x = Letter(code: 30)
    package static let y = Letter(code: 31)
    package static let z = Letter(code: 32)

    /// All letters in code order.
    package static let all: [Letter] = (0..<UInt8(count)).map { Letter(code: $0) }

    // Per-code properties, indexed by `code`.
    private static let baseASCIITable: [UInt8] = Array("aaabcddeefghijklmnooopqrstuuvwxyz".utf8)
    private static let modifierTable: [LetterModifier] = [
        .none, .breve, .circumflex, .none, .none, .none, .stroke, .none, .circumflex, .none, .none,
        .none, .none, .none, .none, .none, .none, .none, .none, .circumflex, .horn, .none, .none,
        .none, .none, .none, .none, .horn, .none, .none, .none, .none, .none,
    ]
    /// Bit `code` is set for the 12 vowel letters a ă â e ê i o ô ơ u ư y (spec 3.2).
    private static let vowelMask: UInt64 = {
        var mask: UInt64 = 0
        for code: UInt8 in [0, 1, 2, 7, 8, 12, 18, 19, 20, 26, 27, 31] { mask |= 1 << UInt64(code) }
        return mask
    }()
    /// Code of each ASCII letter `a...z`, indexed by `ascii - 97`.
    private static let codeForASCII: [UInt8] = [
        0, 3, 4, 5, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21, 22, 23, 24, 25, 26, 28, 29, 30, 31, 32,
    ]

    /// The unmodified ASCII letter this letter is written with (`ư` -> `u`, `đ` -> `d`).
    @inline(__always)
    package var baseASCII: UInt8 { Letter.baseASCIITable[Int(code)] }

    @inline(__always)
    package var modifier: LetterModifier { Letter.modifierTable[Int(code)] }

    /// One of the 12 vowel letters `a ă â e ê i o ô ơ u ư y`.
    @inline(__always)
    package var isVowel: Bool { Letter.vowelMask & (1 << UInt64(code)) != 0 }

    /// Every letter that is not a vowel letter, including `f j w z`.
    @inline(__always)
    package var isConsonant: Bool { !isVowel }

    /// A vowel letter with a breve, circumflex or horn (`ă â ê ô ơ ư`), the letters tone rule 1 looks for.
    @inline(__always)
    package var isModifiedVowel: Bool { isVowel && modifier != .none }

    /// The same letter without modifier or stroke.
    @inline(__always)
    package var unmodified: Letter { Letter(asciiLowercase: baseASCII)! }

    /// The letter for a lowercase ASCII letter `a...z`, nil for anything else.
    @inline(__always)
    package init?(asciiLowercase ascii: UInt8) {
        guard ascii >= 97, ascii <= 122 else { return nil }
        self.init(code: Letter.codeForASCII[Int(ascii - 97)])
    }

    /// The letter for an ASCII letter of either case, nil for anything else. Case folding is ASCII
    /// only, never locale dependent (ENG-R905).
    @inline(__always)
    package init?(ascii: UInt8) {
        if ascii >= 65, ascii <= 90 {
            self.init(asciiLowercase: ascii + 32)
        } else {
            self.init(asciiLowercase: ascii)
        }
    }

    /// This letter's base with `modifier` applied, or nil when the combination does not exist
    /// (only ă â ê ô ơ ư đ exist). `.none` returns the unmodified letter.
    package func applying(_ modifier: LetterModifier) -> Letter? {
        let base = unmodified
        switch (base.code, modifier) {
        case (_, .none): return base
        case (Letter.a.code, .breve): return .aBreve
        case (Letter.a.code, .circumflex): return .aCircumflex
        case (Letter.e.code, .circumflex): return .eCircumflex
        case (Letter.o.code, .circumflex): return .oCircumflex
        case (Letter.o.code, .horn): return .oHorn
        case (Letter.u.code, .horn): return .uHorn
        case (Letter.d.code, .stroke): return .dStroke
        default: return nil
        }
    }

    /// Whether this letter, typed without a modifier, may stand for `other` under the viability
    /// wildcard of ENG-R345: an unmodified vowel matches the same vowel with any modifier and `d`
    /// matches `d` or `đ`; every other letter matches only itself.
    @inline(__always)
    package func viabilityMatches(_ other: Letter) -> Bool {
        if self == other { return true }
        guard modifier == .none, other.baseASCII == baseASCII else { return false }
        return isVowel || self == .d
    }

    /// The lowercase spelling of this letter.
    package var character: Character { Character(LetterTable.scalar(self, tone: .level, uppercase: false)) }

    package var description: String { String(character) }
}

extension Letter {
    /// Parses a lowercase spelling made of engine letters (`"nghiêng"`), for tables and tests.
    /// Returns nil if a character is not one of the 33 letters (tone marks are not letters).
    package static func letters(_ spelling: some StringProtocol) -> [Letter]? {
        var result: [Letter] = []
        result.reserveCapacity(spelling.unicodeScalars.count)
        for scalar in spelling.unicodeScalars {
            guard let glyph = LetterTable.glyph(for: scalar), glyph.tone == .level, !glyph.isUppercase else {
                return nil
            }
            result.append(glyph.letter)
        }
        return result
    }

    /// The lowercase spelling of a letter sequence.
    package static func spelling(_ letters: some Sequence<Letter>) -> String {
        var text = ""
        for letter in letters { text.unicodeScalars.append(LetterTable.scalar(letter, tone: .level, uppercase: false)) }
        return text
    }
}
