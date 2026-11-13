// SPDX-License-Identifier: MPL-2.0

/// How a key event is treated while composing: a key of the token, or a boundary that ends it (9.2).
package enum TokenKey: Sendable, Hashable {
    /// An ASCII key that belongs to the token: a letter, a main-row digit in VNI, or a bracket key in
    /// Telex with the bracket option.
    case token(UInt8)
    /// A boundary. Hard boundaries (Return, Tab) also clear the history after the commit (ENG-R912).
    case boundary(isHard: Bool)

    /// Classifies one key under `rules` (spec 9.2 table, ENG-R401 to ENG-R403):
    /// - ASCII letters are token keys in both methods;
    /// - main-row digits are token keys in VNI and boundaries in Telex; keypad digits are always
    ///   boundaries (ENG-R401); shifted digits arrive as symbols and are boundaries (ENG-R402);
    /// - `[` and `]` are token keys only in Telex with the bracket option (ENG-R104);
    /// - whitespace, ASCII punctuation and symbols, control characters and every non-ASCII character
    ///   (letters from other layouts, precomposed Vietnamese letters) are boundaries.
    @inline(__always)
    package static func classify(_ input: KeyInput, rules: ComposerRules) -> TokenKey {
        // `Character.asciiValue` maps "\r\n" to "\n"; any other multi-scalar character is non-ASCII.
        guard let byte = input.character.asciiValue else { return .boundary(isHard: false) }
        if ASCII.isLetter(byte) { return .token(byte) }
        if ASCII.isDigit(byte) {
            return !rules.isTelex && !input.fromKeypad ? .token(byte) : .boundary(isHard: false)
        }
        if byte == ASCII.leftBracket || byte == ASCII.rightBracket {
            return rules.isTelex && rules.bracketKeys ? .token(byte) : .boundary(isHard: false)
        }
        // ENG-R912: Return and Tab. A carriage return is treated as Return.
        return .boundary(isHard: byte == 0x0A || byte == 0x0D || byte == 0x09)
    }
}
