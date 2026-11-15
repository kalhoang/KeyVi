// SPDX-License-Identifier: MPL-2.0

// ENG-R711, last resort of Backspace on an escape letter: when no replay of the remaining keys gives the
// old display minus its last character, the token is rebuilt from keys that type the letters shown,
// one letter at a time. ENG-R601 still holds: the new raw keys replay to the new state.

extension Composition {
    /// A composition whose display is `expected`, typed from the first `count` letters of this one: each
    /// letter's key followed at once by the key of its mark, and the tone key after the letter that gives
    /// `expected`, tried from the last letter back. A bracket letter shown without its mark is typed as
    /// its plain base letter, or else as the bracket key and a mark removal (ENG-R411), for a token whose
    /// plain letter would make it camel case (ENG-R904). Nil when no such order gives `expected` (none is
    /// known; the Backspace property tests and the fuzz campaign, ENG-T38, would report one).
    ///
    /// Typing each mark next to its letter is what makes it work where the replay does not: the order in
    /// which the keys were first typed made a transform viable that the remaining letters no longer allow
    /// in that order (`dwndw` shows `đnw`: the `d` stroke applied while the `ư` stood, so Backspace gives
    /// `đn` typed `ddn`).
    func retyped(letterCount count: Int, expected: String, rules: ComposerRules) -> Composition? {
        for removingBracketMarks in [false, true] {
            var keys: [UInt8] = []
            var capsLock = KeySet()
            var letterEnds: [Int] = []
            let style = RetypingStyle(
                bracketsInAllCaps: bracketLettersFollowAllCaps, removingBracketMarks: removingBracketMarks)
            for letter in letters.prefix(count) {
                appendKeys(typing: letter, style: style, to: &keys, capsLock: &capsLock, rules: rules)
                letterEnds.append(keys.count)
            }
            if tone == .level {
                if let result = composition(of: keys, capsLock, ifShowing: expected, rules: rules) { return result }
                continue
            }
            let toneKey = Self.toneKey(tone, rules: rules)
            for end in letterEnds.reversed() {
                var toned = keys
                toned.insert(toneKey, at: end)
                let shifted = capsLock.inserting(at: end)
                if let result = composition(of: toned, shifted, ifShowing: expected, rules: rules) { return result }
            }
        }
        return nil
    }

    private struct RetypingStyle {
        /// ENG-R906: the bracket letters are shown uppercase because the token is an all-caps word.
        let bracketsInAllCaps: Bool
        /// A bracket letter shown without its mark is typed as its bracket key and a mark removal.
        let removingBracketMarks: Bool
    }

    private func composition(of keys: [UInt8], _ capsLock: KeySet, ifShowing expected: String, rules: ComposerRules)
        -> Composition?
    {
        let result = Composition(replaying: keys, capsLockKeys: capsLock, rules: rules)
        return result.display(style: rules.toneStyle) == expected ? result : nil
    }

    /// The keys that type `composed` under `rules`: a bracket letter keeps its bracket key when it shows
    /// its mark (ENG-R104, with Caps Lock when it shows uppercase, ENG-R906); any other letter is its base
    /// key in its case, then the key of its mark (ENG-R412 to ENG-R415).
    private func appendKeys(
        typing composed: ComposedLetter, style: RetypingStyle, to keys: inout [UInt8], capsLock: inout KeySet,
        rules: ComposerRules
    ) {
        let letter = composed.letter
        let isBracket = composed.flags.contains(.bracket) && rules.bracketKeys
        let base = letter.baseASCII
        let isBracketBase = base == UInt8(ascii: "o") || base == UInt8(ascii: "u")
        if isBracket, isBracketBase, letter.modifier == .horn || style.removingBracketMarks {
            if composed.isUppercase || style.bracketsInAllCaps { capsLock.formUnion(KeySet(index: keys.count)) }
            keys.append(base == UInt8(ascii: "o") ? ASCII.leftBracket : ASCII.rightBracket)
            if letter.modifier == .none { keys.append(UInt8(ascii: rules.isTelex ? "z" : "0")) }
            return
        }
        keys.append(composed.isUppercase ? base - 32 : base)
        guard let markKey = Self.markKey(letter.modifier, base: base, rules: rules) else { return }
        keys.append(markKey)
    }

    private static func markKey(_ modifier: LetterModifier, base: UInt8, rules: ComposerRules) -> UInt8? {
        switch modifier {
        case .none: return nil
        case .circumflex: return rules.isTelex ? base : UInt8(ascii: "6")
        case .horn: return UInt8(ascii: rules.isTelex ? "w" : "7")
        case .breve: return UInt8(ascii: rules.isTelex ? "w" : "8")
        case .stroke: return rules.isTelex ? UInt8(ascii: "d") : UInt8(ascii: "9")
        }
    }

    private static func toneKey(_ tone: Tone, rules: ComposerRules) -> UInt8 {
        let keys: (telex: Character, vni: Character)
        switch tone {
        case .level: keys = ("z", "0")
        case .acute: keys = ("s", "1")
        case .grave: keys = ("f", "2")
        case .hook: keys = ("r", "3")
        case .tilde: keys = ("x", "4")
        case .dot: keys = ("j", "5")
        }
        return (rules.isTelex ? keys.telex : keys.vni).asciiValue ?? 0
    }
}
