// SPDX-License-Identifier: MPL-2.0

/// One rhyme spelling (vowel group plus consonant coda, spec 3.1) with the properties the
/// spelling rules of 3.10 to 3.12 look at. All properties are derived from the letters.
package struct Rhyme: Sendable, Hashable, CustomStringConvertible {
    package enum CodaKind: UInt8, Sendable, Hashable {
        /// No consonant coda (open rhyme or semivowel ending).
        case none
        /// `m n ng nh`: all six tones.
        case sonorant
        /// `c ch p t`: only sắc and nặng (ENG-R320).
        case stop
        /// Tier B `k`, a spelling variant of `c` that takes all six tones (ENG-R321).
        case k
    }

    /// Index in `SyllableTables.rhymes`.
    package let id: Int
    package let spelling: String
    package let letters: [Letter]
    /// Number of vowel letters (the vowel group).
    package let vowelCount: Int
    package let coda: CodaKind
    /// Starts with a medial glide: `oa… oă… oe… uâ… uê… uy… (uya uyê…) uơ` (ENG-R312).
    package let isMedial: Bool
    /// Starts with the medial `o` (`oa… oă… oe…`).
    package let hasOMedial: Bool
    /// Starts with `e ê i y` (this covers `iê ia`), the vowels of ENG-R310.
    package let isFront: Bool

    package init(id: Int, spelling: String) {
        guard let letters = Letter.letters(spelling), !letters.isEmpty else {
            preconditionFailure("rhyme spelling must use engine letters")
        }
        self.id = id
        self.spelling = spelling
        self.letters = letters
        vowelCount = letters.prefix(while: \.isVowel).count
        let codaSpelling = String(spelling.unicodeScalars.dropFirst(vowelCount).map(Character.init))
        switch codaSpelling {
        case "": coda = .none
        case "c", "ch", "p", "t": coda = .stop
        case "k": coda = .k
        default: coda = .sonorant
        }
        let prefix2 = String(spelling.prefix(2))
        isMedial = ["oa", "oă", "oe", "uâ", "uê", "uy", "uơ"].contains(prefix2)
        hasOMedial = ["oa", "oă", "oe"].contains(prefix2)
        isFront = [.e, .eCircumflex, .i, .y].contains(letters[0])
    }

    /// Whether the spelling starts with `prefix`.
    package func starts(with prefix: String) -> Bool { spelling.hasPrefix(prefix) }

    /// The tones this rhyme accepts in its tier (ENG-R320, ENG-R321).
    package func accepts(_ tone: Tone) -> Bool {
        coda != .stop || tone == .acute || tone == .dot
    }

    package var description: String { spelling }
}

/// Packs a rhyme spelling of at most four letters into one integer key, so that the rhyme of the
/// current letters is found with one hash lookup (ENG-R1232). Every rhyme of section 3 has at most
/// four letters; a longer vowel group plus coda has no key and is therefore no rhyme.
package enum RhymeKey {
    package static let maximumLength = 4

    @inline(__always)
    package static func make<C: Collection>(_ letters: C) -> UInt32? where C.Element == Letter {
        var key: UInt32 = 0
        var length = 0
        for letter in letters {
            length += 1
            if length > maximumLength { return nil }
            key = key &* UInt32(Letter.count + 1) &+ UInt32(letter.code) &+ 1
        }
        return length == 0 ? nil : key
    }
}
