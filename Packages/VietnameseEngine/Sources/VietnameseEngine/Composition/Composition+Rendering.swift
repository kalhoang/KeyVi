// SPDX-License-Identifier: MPL-2.0

extension Composition {
    /// The display of the token (6.1): the letters normalised for display (ENG-R530, ENG-R531) with the
    /// tone placed by 5.1 / 5.2 on the current letters (ENG-R501), each letter in the case of its key
    /// (ENG-R901; bracket letters by ENG-R906), then the literal tail exactly as typed (ENG-R420).
    /// Precomposed letters only (ENG-R102).
    package func display(style: ToneStyle) -> String {
        render(style: style, committed: false)
    }

    /// ENG-R532, ENG-R317: the text a commit writes for the composed form. An open `ươ` (no coda, no ending) is
    /// written `uơ` with the tone on `ơ` (`thưở` -> `thuở`, `hươ` -> `huơ`). Literal tokens keep their
    /// display: their vowel group is never open because the literal tail follows it. The commit (8.1)
    /// calls this when it keeps the composed form.
    package func committedText(style: ToneStyle) -> String {
        render(style: style, committed: true)
    }

    /// Whether a commit that keeps the composed form writes it with the ENG-R532 spelling `uơ`, so that
    /// `committedText(style:)` differs from `display(style:)` (the same test `render` applies).
    package var writesOpenHornPairAtCommit: Bool {
        guard literalStart == nil else { return false }
        let view = LetterView(letters)
        let parse = SyllableParser.parse(view)
        return HornNormalisation.isOpenHornPair(DisplayLetterView(view, parse: parse), parse: parse)
    }

    private func render(style: ToneStyle, committed: Bool) -> String {
        let view = LetterView(letters)
        let parse = SyllableParser.parse(view)
        let displayLetters = DisplayLetterView(view, parse: parse)
        let toneOffset =
            tone == .level ? nil : TonePlacement.toneOffset(in: displayLetters, parse: parse, style: style)
        let openPairToWrite =
            committed && literalStart == nil && HornNormalisation.isOpenHornPair(displayLetters, parse: parse)
        let bracketsInAllCaps = bracketLettersFollowAllCaps
        var text = ""
        let tailCount = literalStart.map { raw.count - $0 } ?? 0
        text.reserveCapacity(letters.count * 3 + tailCount)
        for offset in 0..<letters.count {
            var letter = displayLetters[offset]
            if openPairToWrite, offset == parse.vowelStart { letter = .u }
            let composed = letters[offset]
            let uppercase = composed.isUppercase || (bracketsInAllCaps && composed.flags.contains(.bracket))
            let scalar = LetterTable.scalar(letter, tone: offset == toneOffset ? tone : .level, uppercase: uppercase)
            text.unicodeScalars.append(scalar)
        }
        if let literalStart {
            // The literal tail is ASCII keys: one validated copy, not one append per key (REG-02).
            text += String(decoding: raw[literalStart...], as: UTF8.self)
        }
        return text
    }

    /// ENG-R906: the token has bracket letters and is an all-caps word, meaning at least two other letters
    /// were produced by keys with a case and all of them are uppercase. Stops at the first lowercase letter.
    var bracketLettersFollowAllCaps: Bool {
        var hasBracketLetter = false
        var uppercaseLetters = 0
        for letter in letters {
            if letter.flags.contains(.bracket) {
                hasBracketLetter = true
            } else if letter.isUppercase {
                uppercaseLetters += 1
            } else {
                return false
            }
        }
        return hasBracketLetter && uppercaseLetters >= 2
    }

    /// The raw keys as a string (restore reproduces them exactly, ENG-R705).
    package var rawText: String { ASCII.string(raw) }
}

extension Composition {
    /// ENG-R710, ENG-R711: one Backspace on the token. In composing mode the keys removed are the key
    /// that produced the last letter, its modifier and stroke keys (except a key that a letter that
    /// stays still needs, see below), and every tone key if the tone is shown on it; for a letter
    /// produced by an escape only the escaping key. In literal mode (and with no letters) the last raw
    /// key is removed. The state is then recomputed by replay (ENG-R601).
    ///
    /// A modifier key that also marked a letter that stays, where that letter still shows the mark and
    /// has no mark key of its own, stays too: `thuowr` + Backspace gives `thư`, not `thu` (one Telex
    /// `w` or VNI `7` on `uo`). With a mark key of its own (`thuwowr`) the shared key goes, since
    /// keeping it would replay as an escape (`thuww`).
    ///
    /// The horn keys of a `u` that shows no horn go with the letter after it: after a circumflex
    /// replaced the horns of `ươ` (ENG-R533, `tuwoo` shows `tuô`, Backspace gives `tu`), and when the
    /// token was re-opened from history with the commit spelling `uơ` of an open `ươ`
    /// (`showsCommittedSpelling`, ENG-R532, ENG-R1002: re-opened `thuở` + Backspace gives `thu`).
    ///
    /// The tone keys go with the letter the tone is or would be shown on: after a removal (ENG-R411,
    /// Telex `z`, VNI `0`) the tone is level, and leaving the tone key and the removal key behind would
    /// replay them as letters or digits (`asz` + Backspace showing `sz`).
    package mutating func backspace(rules: ComposerRules, showsCommittedSpelling: Bool = false) {
        guard literalStart == nil, let last = letters.last else {
            removeLastKey(rules: rules)
            return
        }
        var removed = KeySet(index: Int(last.source))
        if !last.flags.contains(.escape) {
            removed.formUnion(modifierKeysLeavingWith(last))
            if let uOffset = unshownHornBeforeLast(showsCommittedSpelling: showsCommittedSpelling) {
                removed.formUnion(letters[uOffset].modifierSources)
            }
            if placementOffset(style: rules.toneStyle) == letters.count - 1 { removed.formUnion(toneSources) }
        }
        var kept: [UInt8] = []
        kept.reserveCapacity(raw.count)
        var keptCapsLock = KeySet()  // ENG-R906: the Caps Lock state moves with each kept key
        for (index, key) in raw.enumerated() where !removed.contains(index) {
            if capsLockKeys.contains(index) { keptCapsLock.formUnion(KeySet(index: kept.count)) }
            kept.append(key)
        }
        self = Composition(replaying: kept, capsLockKeys: keptCapsLock, rules: rules)
    }

    /// ENG-R710: the modifier and stroke keys of `last` that go with it. A letter that stays and still
    /// shows its mark, with every one of its mark keys shared with `last`, keeps exactly one of them:
    /// the newest, which gave the mark it shows (`uo76m7` in VNI: the second `7` re-applied the horns
    /// after the `6`; keeping both `7`s would replay as an escape). The `ư` of a standalone `w` and the
    /// letters of bracket keys carry their mark from their own key (ENG-R103, ENG-R104): `wow` shows
    /// `ươ`, Backspace gives `ư`.
    private func modifierKeysLeavingWith(_ last: ComposedLetter) -> KeySet {
        var needed = KeySet()
        for letter in letters.dropLast() where letter.letter.modifier != .none {
            guard !letter.flags.contains(.standaloneW), !letter.flags.contains(.bracket) else { continue }
            let shared = letter.modifierSources.intersection(last.modifierSources)
            if !shared.isEmpty, letter.modifierSources.subtracting(last.modifierSources).isEmpty {
                needed.formUnion(shared.newest)
            }
        }
        return last.modifierSources.subtracting(needed)
    }

    /// The offset of the `u` just before the last letter when its horn keys are not shown: the last
    /// letter is the `ô` whose circumflex removed the horns of `ươ` (ENG-R533), or the token shows the
    /// commit spelling `uơ` of an open `ươ` (ENG-R532). Nil otherwise.
    private func unshownHornBeforeLast(showsCommittedSpelling: Bool) -> Int? {
        let uOffset = letters.count - 2
        guard uOffset >= 0, letters[uOffset].letter.unmodified == .u else { return nil }
        let parse = self.parse
        guard uOffset >= parse.vowelStart, uOffset + 1 < parse.codaStart else { return nil }
        let lastLetter = letters[uOffset + 1].letter
        if lastLetter == .oCircumflex, letters[uOffset].letter == .u { return uOffset }
        guard showsCommittedSpelling else { return nil }
        let view = LetterView(letters)
        return HornNormalisation.isOpenHornPair(DisplayLetterView(view, parse: parse), parse: parse) ? uOffset : nil
    }

    /// Removes the last raw key and recomputes. Dropping a key of a literal tail after the key that
    /// started literal mode leaves the state that replay would rebuild, so it is done in place (this
    /// keeps very long literal tokens linear, ENG-R640); otherwise the remaining keys, at most
    /// `composingKeyLimit`, are replayed.
    package mutating func removeLastKey(rules: ComposerRules) {
        guard !raw.isEmpty else { return }
        if let literalStart, raw.count - 1 > literalStart {
            popLastRawKey()
            return
        }
        self = Composition(replaying: raw.dropLast(), capsLockKeys: capsLockKeys, rules: rules)
    }
}
