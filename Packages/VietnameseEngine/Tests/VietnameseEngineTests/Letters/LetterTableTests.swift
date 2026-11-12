// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine

/// ENG-R301: the generated table of the 146 emittable letters, re-derived here from Unicode data
/// through Foundation (an implementation independent of the Python generator).
@Suite("Generated letter table (ENG-R301)")
struct LetterTableTests {
    private static let vowels: [(base: String, modifier: LetterModifier, mark: String)] = [
        ("a", .none, ""), ("a", .breve, "\u{0306}"), ("a", .circumflex, "\u{0302}"), ("e", .none, ""),
        ("e", .circumflex, "\u{0302}"), ("i", .none, ""), ("o", .none, ""), ("o", .circumflex, "\u{0302}"),
        ("o", .horn, "\u{031B}"), ("u", .none, ""), ("u", .horn, "\u{031B}"), ("y", .none, ""),
    ]
    private static let toneMarks: [(Tone, String)] = [
        (.level, ""), (.acute, "\u{0301}"), (.grave, "\u{0300}"), (.hook, "\u{0309}"), (.tilde, "\u{0303}"),
        (.dot, "\u{0323}"),
    ]

    @Test func tableHas146LettersOrderedByCodePoint() {
        let values = LetterTable.entries.map(\.scalarValue)
        #expect(values.count == 146)
        #expect(Set(values).count == 146)
        #expect(values == values.sorted())
    }

    @Test func tableEqualsRederivationFromUnicodeData() throws {
        var derived: [LetterTableEntry] = []
        for vowel in Self.vowels {
            for (tone, toneMark) in Self.toneMarks {
                for upper in [false, true] {
                    let text = (upper ? vowel.base.uppercased() : vowel.base) + vowel.mark + toneMark
                    let composed = text.precomposedStringWithCanonicalMapping
                    let scalars = Array(composed.unicodeScalars)
                    try #require(scalars.count == 1, "no precomposed form for \(text)")
                    derived.append(
                        LetterTableEntry(
                            scalars[0].value, Unicode.Scalar(vowel.base)!, vowel.modifier, tone, uppercase: upper))
                }
            }
        }
        for (upper, name) in [
            (false, "LATIN SMALL LETTER D WITH STROKE"), (true, "LATIN CAPITAL LETTER D WITH STROKE"),
        ] {
            let scalar = try #require(
                (0x0100...0x017F).compactMap(Unicode.Scalar.init).first { $0.properties.name == name })
            derived.append(LetterTableEntry(scalar.value, "d", .stroke, .level, uppercase: upper))
        }
        derived.sort { $0.scalarValue < $1.scalarValue }
        #expect(derived == LetterTable.entries)
    }

    @Test func entriesAgreeWithUnicodeCharacterNames() {
        let toneWords: [Tone: String] = [
            .acute: "ACUTE", .grave: "GRAVE", .hook: "HOOK ABOVE", .tilde: "TILDE", .dot: "DOT BELOW",
        ]
        let modifierWords: [LetterModifier: String] = [
            .breve: "BREVE", .circumflex: "CIRCUMFLEX", .horn: "HORN", .stroke: "STROKE",
        ]
        for entry in LetterTable.entries {
            let name = entry.scalar.properties.name ?? ""
            #expect(name.hasPrefix(entry.isUppercase ? "LATIN CAPITAL LETTER " : "LATIN SMALL LETTER "), "\(name)")
            #expect(name.contains("LETTER \(String(entry.base).uppercased())"), "\(name)")
            if let word = toneWords[entry.tone] { #expect(name.contains(word), "\(name)") }
            if let word = modifierWords[entry.modifier] { #expect(name.contains(word), "\(name)") }
            #expect(entry.scalar.properties.canonicalCombiningClass == .notReordered)
        }
    }

    @Test func untonedASCIIVowelsArePlainASCII() {
        let ascii = LetterTable.entries.filter { $0.scalarValue < 0x80 }.map { Character($0.scalar) }
        #expect(Set(ascii) == Set("aeiouyAEIOUY"))
    }

    @Test func encodeAndDecodeRoundTrip() {
        for letter in Letter.all {
            for tone in Tone.allTones where LetterTable.canCarry(letter, tone: tone) {
                for upper in [false, true] {
                    let scalar = LetterTable.scalar(letter, tone: tone, uppercase: upper)
                    let glyph = LetterTable.glyph(for: scalar)
                    #expect(glyph == Glyph(letter: letter, tone: tone, isUppercase: upper))
                }
            }
        }
        #expect(LetterTable.glyph(for: "1") == nil)
        #expect(LetterTable.glyph(for: "\u{0301}") == nil)
        #expect(LetterTable.glyph(for: "é")?.letter == .e)
    }

    @Test func tonesOnlyOnVowels() {
        for letter in Letter.all {
            #expect(LetterTable.canCarry(letter, tone: .acute) == letter.isVowel, "\(letter)")
        }
        // A tone requested on a consonant falls back to the plain letter.
        #expect(LetterTable.scalar(.b, tone: .acute, uppercase: true) == "B")
    }
}

@Suite("Letter model")
struct LetterTests {
    @Test func alphabetHas33LettersAnd12Vowels() {
        #expect(Letter.all.count == 33)
        #expect(Letter.spelling(Letter.all) == "aăâbcdđeêfghijklmnoôơpqrstuưvwxyz")
        #expect(String(Letter.all.filter(\.isVowel).map(\.character)) == "aăâeêioôơuưy")
    }

    @Test func asciiMappingIsCaseInsensitive() {
        for ascii in UInt8(97)...122 {
            let lower = Letter(ascii: ascii)
            #expect(lower != nil)
            #expect(Letter(ascii: ascii - 32) == lower)
            #expect(lower?.baseASCII == ascii)
            #expect(lower?.modifier == LetterModifier.none)
        }
        #expect(Letter(ascii: UInt8(ascii: "1")) == nil)
        #expect(Letter(ascii: UInt8(ascii: "[")) == nil)
    }

    @Test func modifiersApplyOnlyWhereTheyExist() {
        #expect(Letter.a.applying(.breve) == .aBreve)
        #expect(Letter.a.applying(.circumflex) == .aCircumflex)
        #expect(Letter.oHorn.applying(.circumflex) == .oCircumflex)
        #expect(Letter.uHorn.applying(LetterModifier.none) == .u)
        #expect(Letter.d.applying(.stroke) == .dStroke)
        #expect(Letter.e.applying(.horn) == nil)
        #expect(Letter.i.applying(.circumflex) == nil)
        #expect(Letter.b.applying(.stroke) == nil)
        #expect(Letter.aCircumflex.unmodified == .a)
        #expect(Letter.dStroke.unmodified == .d)
    }

    @Test func viabilityWildcard() {
        // ENG-R345: unmodified vowel matches any modifier; d matches đ; modified matches only itself.
        #expect(Letter.a.viabilityMatches(.aBreve))
        #expect(Letter.a.viabilityMatches(.aCircumflex))
        #expect(Letter.o.viabilityMatches(.oHorn))
        #expect(Letter.u.viabilityMatches(.uHorn))
        #expect(Letter.d.viabilityMatches(.dStroke))
        #expect(!Letter.aBreve.viabilityMatches(.a))
        #expect(!Letter.aBreve.viabilityMatches(.aCircumflex))
        #expect(!Letter.dStroke.viabilityMatches(.d))
        #expect(!Letter.i.viabilityMatches(.y))
        #expect(Letter.all.allSatisfy { $0.viabilityMatches($0) })
    }

    @Test func modifiedVowels() {
        #expect(String(Letter.all.filter(\.isModifiedVowel).map(\.character)) == "ăâêôơư")
        #expect(!Letter.dStroke.isModifiedVowel)
    }
}
