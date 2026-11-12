// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// The public `Orthography.analyze` (ENG-R1212).
@Suite("Orthography.analyze (ENG-R1212)")
struct OrthographyAnalyzeTests {
    @Test func fieldsOfAStandardWord() {
        let analysis = Orthography.analyze("Nghiêng")
        #expect(
            analysis
                == SyllableAnalysis(
                    onset: "ngh", vowelGroup: "iê", coda: "ng", tone: .level, validity: .standard, toneLetterOffset: nil
                ))
    }

    @Test func toneAndItsOffset() {
        #expect(
            Orthography.analyze("việt")
                == SyllableAnalysis(
                    onset: "v", vowelGroup: "iê", coda: "t", tone: .dot, validity: .standard, toneLetterOffset: 2))
        #expect(Orthography.analyze("hòa").toneLetterOffset == 1)
        #expect(Orthography.analyze("hoà").toneLetterOffset == 2)
        #expect(
            Orthography.analyze("QUỐC")
                == SyllableAnalysis(
                    onset: "qu", vowelGroup: "ô", coda: "c", tone: .acute, validity: .standard, toneLetterOffset: 2))
        #expect(
            Orthography.analyze("giếc")
                == SyllableAnalysis(
                    onset: "gi", vowelGroup: "ê", coda: "c", tone: .acute, validity: .standard, toneLetterOffset: 2))
        #expect(
            Orthography.analyze("gì")
                == SyllableAnalysis(
                    onset: "g", vowelGroup: "i", coda: "", tone: .grave, validity: .standard, toneLetterOffset: 1))
    }

    @Test func extendedAndInvalidWords() {
        #expect(
            Orthography.analyze("Đắk")
                == SyllableAnalysis(
                    onset: "đ", vowelGroup: "ă", coda: "k", tone: .acute, validity: .extended, toneLetterOffset: 1))
        #expect(
            Orthography.analyze("dzậy")
                == SyllableAnalysis(
                    onset: "dz", vowelGroup: "ây", coda: "", tone: .dot, validity: .extended, toneLetterOffset: 2))
        let mother = Orthography.analyze("mother")
        #expect(mother.validity == .invalid)
        #expect(mother.onset == "m" && mother.vowelGroup == "o" && mother.coda == "th")
        #expect(Orthography.analyze("nghãi").validity == .invalid)
    }

    @Test func nonWords() {
        let empty = SyllableAnalysis(
            onset: "", vowelGroup: "", coda: "", tone: .level, validity: .invalid, toneLetterOffset: nil)
        #expect(Orthography.analyze("") == empty)
        #expect(Orthography.analyze("a1") == empty)
        #expect(Orthography.analyze("hello world") == empty)
        let twoTones = Orthography.analyze("áá")
        #expect(twoTones.validity == .invalid)
        #expect(twoTones.tone == .acute && twoTones.toneLetterOffset == 0)
    }

    @Test func validityAgreesWithAnalyze() {
        for word in ["việt", "Krông", "nghô", "thuở", "thươ", "quởn", "", "x1", "áá"] {
            #expect(Orthography.validity(of: word) == Orthography.analyze(word).validity, "\(word)")
        }
    }
}
