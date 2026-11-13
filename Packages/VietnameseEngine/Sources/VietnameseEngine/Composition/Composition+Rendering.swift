// SPDX-License-Identifier: MPL-2.0

extension Composition {
    /// The display of the token (6.1): the letters normalised for display (ENG-R530, ENG-R531) with the
    /// tone placed by 5.1 / 5.2 on the current letters (ENG-R501), each letter in the case of its key
    /// (ENG-R901), then the literal tail exactly as typed (ENG-R420). Precomposed letters only
    /// (ENG-R102).
    package func display(style: ToneStyle) -> String {
        render(style: style, committed: false)
    }

    /// ENG-R532: the text a commit writes for the composed form. An open `ươ` (no coda, no ending) is
    /// written `uơ` with the tone on `ơ` (`thưở` -> `thuở`, `hươ` -> `huơ`). Literal tokens keep their
    /// display: their vowel group is never open because the literal tail follows it. The commit (8.1)
    /// calls this when it keeps the composed form.
    package func committedText(style: ToneStyle) -> String {
        render(style: style, committed: true)
    }

    private func render(style: ToneStyle, committed: Bool) -> String {
        let view = LetterView(letters)
        let parse = SyllableParser.parse(view)
        let displayLetters = DisplayLetterView(view, parse: parse)
        let toneOffset =
            tone == .level ? nil : TonePlacement.toneOffset(in: displayLetters, parse: parse, style: style)
        let openPairToWrite =
            committed && literalStart == nil && HornNormalisation.isOpenHornPair(displayLetters, parse: parse)
        var text = ""
        let tailCount = literalStart.map { raw.count - $0 } ?? 0
        text.reserveCapacity(letters.count * 3 + tailCount)
        for offset in 0..<letters.count {
            var letter = displayLetters[offset]
            if openPairToWrite, offset == parse.vowelStart { letter = .u }
            let scalar = LetterTable.scalar(
                letter, tone: offset == toneOffset ? tone : .level, uppercase: letters[offset].isUppercase)
            text.unicodeScalars.append(scalar)
        }
        if let literalStart {
            // The literal tail is ASCII keys: one validated copy, not one append per key (REG-02).
            text += String(decoding: raw[literalStart...], as: UTF8.self)
        }
        return text
    }

    /// The raw keys as a string (restore reproduces them exactly, ENG-R705).
    package var rawText: String { ASCII.string(raw) }
}

extension Composition {
    /// ENG-R710, ENG-R711: one Backspace on the token. In composing mode the keys removed are the key
    /// that produced the last letter, every modifier or stroke key that targeted it, and every tone
    /// key if the tone is shown on it; for a letter produced by an escape only the escaping key. In
    /// literal mode (and with no letters) the last raw key is removed. The state is then recomputed by
    /// replay (ENG-R601).
    ///
    /// The tone keys go with the letter the tone is or would be shown on: after a removal (ENG-R411,
    /// Telex `z`, VNI `0`) the tone is level, and leaving the tone key and the removal key behind would
    /// replay them as letters or digits (`asz` + Backspace showing `sz`).
    package mutating func backspace(rules: ComposerRules) {
        guard literalStart == nil, let last = letters.last else {
            removeLastKey(rules: rules)
            return
        }
        var removed = KeySet(index: Int(last.source))
        if !last.flags.contains(.escape) {
            removed.formUnion(last.modifierSources)
            if placementOffset(style: rules.toneStyle) == letters.count - 1 { removed.formUnion(toneSources) }
        }
        var kept: [UInt8] = []
        kept.reserveCapacity(raw.count)
        for (index, key) in raw.enumerated() where !removed.contains(index) { kept.append(key) }
        self = Composition(replaying: kept, rules: rules)
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
        self = Composition(replaying: raw.dropLast(), rules: rules)
    }
}
