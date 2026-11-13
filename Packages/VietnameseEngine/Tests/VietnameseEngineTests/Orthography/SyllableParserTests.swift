// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// Spec 3.13, ENG-R340.
@Suite("Syllable parser (3.13)")
struct SyllableParserTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let word: String
        let onset: String
        let vowelGroup: String
        let coda: String
        let remainder: String
        var testDescription: String { word }
    }

    static let cases: [Case] = [
        Case(word: "nghiêng", onset: "ngh", vowelGroup: "iê", coda: "ng", remainder: ""),
        Case(word: "ngay", onset: "ng", vowelGroup: "ay", coda: "", remainder: ""),
        Case(word: "quy", onset: "qu", vowelGroup: "y", coda: "", remainder: ""),
        Case(word: "quyêt", onset: "qu", vowelGroup: "yê", coda: "t", remainder: ""),
        Case(word: "qu", onset: "qu", vowelGroup: "", coda: "", remainder: ""),
        Case(word: "qa", onset: "q", vowelGroup: "a", coda: "", remainder: ""),
        // ENG-R305 / ENG-R306 / ENG-R307: `gi` is the onset only before a vowel letter.
        Case(word: "gi", onset: "g", vowelGroup: "i", coda: "", remainder: ""),
        Case(word: "gin", onset: "g", vowelGroup: "i", coda: "n", remainder: ""),
        Case(word: "giu", onset: "gi", vowelGroup: "u", coda: "", remainder: ""),
        Case(word: "giup", onset: "gi", vowelGroup: "u", coda: "p", remainder: ""),
        Case(word: "giêng", onset: "gi", vowelGroup: "ê", coda: "ng", remainder: ""),
        Case(word: "giêc", onset: "gi", vowelGroup: "ê", coda: "c", remainder: ""),
        Case(word: "giưa", onset: "gi", vowelGroup: "ưa", coda: "", remainder: ""),
        // 3.3 `dz` (ENG-R316) and Tier B clusters.
        Case(word: "dzô", onset: "dz", vowelGroup: "ô", coda: "", remainder: ""),
        Case(word: "dzây", onset: "dz", vowelGroup: "ây", coda: "", remainder: ""),
        Case(word: "krông", onset: "kr", vowelGroup: "ô", coda: "ng", remainder: ""),
        Case(word: "đrăk", onset: "đr", vowelGroup: "ă", coda: "k", remainder: ""),
        Case(word: "đăk", onset: "đ", vowelGroup: "ă", coda: "k", remainder: ""),
        Case(word: "plông", onset: "pl", vowelGroup: "ô", coda: "ng", remainder: ""),
        Case(word: "za", onset: "z", vowelGroup: "a", coda: "", remainder: ""),
        Case(word: "thuơ", onset: "th", vowelGroup: "uơ", coda: "", remainder: ""),
        Case(word: "ưa", onset: "", vowelGroup: "ưa", coda: "", remainder: ""),
        Case(word: "uyên", onset: "", vowelGroup: "uyê", coda: "n", remainder: ""),
        Case(word: "boong", onset: "b", vowelGroup: "oo", coda: "ng", remainder: ""),
        // Non-syllables still parse deterministically.
        Case(word: "mother", onset: "m", vowelGroup: "o", coda: "th", remainder: "er"),
        Case(word: "keyboard", onset: "k", vowelGroup: "ey", coda: "b", remainder: "oard"),
        Case(word: "startup", onset: "s", vowelGroup: "", coda: "t", remainder: "artup"),
        Case(word: "ddi", onset: "d", vowelGroup: "", coda: "d", remainder: "i"),
        Case(word: "ngh", onset: "ngh", vowelGroup: "", coda: "", remainder: ""),
        Case(word: "facebook", onset: "f", vowelGroup: "a", coda: "c", remainder: "ebook"),
        Case(word: "w", onset: "w", vowelGroup: "", coda: "", remainder: ""),
        Case(word: "", onset: "", vowelGroup: "", coda: "", remainder: ""),
    ]

    @Test(arguments: cases)
    func parse(_ example: Case) {
        let word = letters(example.word)
        let parse = SyllableParser.parse(word)
        #expect(parse.onset.spelling == example.onset)
        #expect(Letter.spelling(word[0..<parse.vowelStart]) == example.onset)
        #expect(Letter.spelling(word[parse.vowelRange]) == example.vowelGroup)
        #expect(Letter.spelling(word[parse.codaStart..<parse.remainderStart]) == example.coda)
        #expect(Letter.spelling(word[parse.remainderStart...]) == example.remainder)
        #expect(Letter.spelling(word[parse.rhymeRange]) == example.vowelGroup + example.coda)
        #expect(parse.isWellFormed == (!example.vowelGroup.isEmpty && example.remainder.isEmpty))
    }

    @Test func parseIgnoresTheCollectionType() {
        // ENG-R340: a pure function of the letters; slices with non-zero start index parse the same.
        let word = letters("xnghiêng")
        let slice = word[1...]
        let parse = SyllableParser.parse(slice)
        #expect(parse == SyllableParser.parse(Array(slice)))
        #expect(parse.onset == .ngh)
    }

    @Test func everyInventoryPairParsesBackToItself() {
        for pair in SyllableTables.extendedPairs {
            let parse = SyllableParser.parse(pair.letters)
            #expect(parse.onset == pair.onset, "\(pair.spelling)")
            #expect(parse.vowelStart == pair.onset.letters.count, "\(pair.spelling)")
            #expect(parse.isWellFormed, "\(pair.spelling)")
        }
    }
}
