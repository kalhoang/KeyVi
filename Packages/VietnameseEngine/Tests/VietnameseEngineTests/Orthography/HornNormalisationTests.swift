// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// Spec 5.5 (ENG-R530 to ENG-R532).
@Suite("Horn normalisation (5.5)")
struct HornNormalisationTests {
    private func display(_ spelling: String) -> String { Letter.spelling(HornNormalisation.display(letters(spelling))) }

    private func committed(_ spelling: String) -> String {
        let word = letters(spelling)
        return Letter.spelling(HornNormalisation.committed(word, parse: SyllableParser.parse(word)))
    }

    @Test func hornOnEitherLetterMeansBoth() {
        #expect(display("tuơng") == "tương")  // tuowng
        #expect(display("tương") == "tương")  // tuwowng
        #expect(display("tưong") == "tương")  // tuwong (W123)
        #expect(display("thuơ") == "thươ")  // open pair shown as ươ (ENG-R531)
        #expect(display("huơu") == "hươu")
        #expect(display("tuong") == "tuong")  // no horn: nothing to complete
        #expect(display("tuông") == "tuông")  // circumflex kept
        #expect(display("quơ") == "quơ")  // the u of qu is not in the vowel group
        #expect(display("quơn") == "quơn")
        #expect(display("giuơ") == "giươ")
    }

    @Test func openUoIsCommittedWithoutTheFirstHorn() {
        #expect(committed("thươ") == "thuơ")  // thuowr + space -> thuở
        #expect(committed("hươ") == "huơ")
        #expect(committed("ươ") == "uơ")
        #expect(committed("thương") == "thương")  // closed
        #expect(committed("ngươi") == "ngươi")  // ending
        #expect(committed("quơ") == "quơ")
    }

    @Test func unchangedLettersAreNotCopied() {
        let word = letters("nguyên")
        let result = HornNormalisation.display(word)
        #expect(result == word)
    }
}
