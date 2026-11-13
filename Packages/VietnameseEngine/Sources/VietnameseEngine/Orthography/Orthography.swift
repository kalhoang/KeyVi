// SPDX-License-Identifier: MPL-2.0

/// Public orthography queries for the diagnostics window and tests (ENG-R1212). They run only on
/// text the user explicitly pastes there, never on typed keys.
public enum Orthography: Sendable {
    /// Parses one word (3.13) and classifies it (3.12). Case is ignored (ENG-R332). The word may be
    /// precomposed (NFC) or use combining marks. Placement of the tone is not part of validity
    /// (3.13 step 5): `toneLetterOffset` reports where the word carries its tone, in characters.
    /// A word containing anything other than letters, or more than one tone mark, is invalid.
    public static func analyze(_ word: String) -> SyllableAnalysis {
        guard let decoded = DecodedWord(word) else {
            return SyllableAnalysis(
                onset: "", vowelGroup: "", coda: "", tone: .level, validity: .invalid, toneLetterOffset: nil)
        }
        let letters = decoded.letters
        let parse = SyllableParser.parse(letters)
        let validity =
            decoded.toneCount > 1 ? .invalid : SyllableTables.validity(of: letters, parse: parse, tone: decoded.tone)
        return SyllableAnalysis(
            onset: Letter.spelling(letters[0..<parse.vowelStart]),
            vowelGroup: Letter.spelling(letters[parse.vowelStart..<parse.codaStart]),
            coda: Letter.spelling(letters[parse.codaStart..<parse.remainderStart]),
            tone: decoded.tone,
            validity: validity,
            toneLetterOffset: decoded.toneOffset)
    }

    /// The tier of one word: `.standard` (Tier A), `.extended` (Tier B only) or `.invalid`.
    public static func validity(of word: String) -> Validity {
        guard let decoded = DecodedWord(word), decoded.toneCount <= 1 else { return .invalid }
        return SyllableTables.validity(of: decoded.letters, tone: decoded.tone)
    }
}

/// A word decoded into lowercase letters and its tone.
struct DecodedWord {
    var letters: [Letter] = []
    var tone: Tone = .level
    var toneOffset: Int?
    var toneCount = 0

    /// Nil if the word is empty or a character is not a letter of the engine's alphabet, optionally
    /// written with combining breve, circumflex, horn or tone marks.
    init?(_ word: String) {
        var offset = 0
        for character in word {
            guard let (letter, tone) = Self.decode(character) else { return nil }
            letters.append(letter)
            if tone != .level {
                toneCount += 1
                if toneCount == 1 {
                    self.tone = tone
                    toneOffset = offset
                }
            }
            offset += 1
        }
        if letters.isEmpty { return nil }
    }

    private static func decode(_ character: Character) -> (Letter, Tone)? {
        var scalars = character.unicodeScalars.makeIterator()
        guard let first = scalars.next(), let glyph = LetterTable.glyph(for: first) else { return nil }
        var letter = glyph.letter
        var tone = glyph.tone
        while let mark = scalars.next() {
            if let modifier = modifierMarks[mark.value] {
                guard letter.modifier == .none, let modified = letter.applying(modifier) else { return nil }
                letter = modified
            } else if let markTone = toneMarks[mark.value] {
                guard tone == .level else { return nil }
                tone = markTone
            } else {
                return nil
            }
        }
        guard tone == .level || letter.isVowel else { return nil }
        return (letter, tone)
    }

    private static let modifierMarks: [UInt32: LetterModifier] = [0x0306: .breve, 0x0302: .circumflex, 0x031B: .horn]
    private static let toneMarks: [UInt32: Tone] = [
        0x0301: .acute, 0x0300: .grave, 0x0309: .hook, 0x0303: .tilde, 0x0323: .dot,
    ]
}
