// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Self-tests of the independent oracle (ENG-T01).
@Suite("Syllable oracle (ENG-T01)")
struct SyllableOracleTests {
    private func spell(
        _ onset: String, _ rhyme: String, _ tone: Tone, _ style: ToneStyle = .traditional,
        _ casing: SyllableOracle.Casing = .lowercase, _ form: SyllableOracle.Form = .committed
    ) -> String {
        SyllableOracle.spell(onset: onset, rhyme: rhyme, tone: tone, style: style, casing: casing, form: form)
    }

    @Test func knownSpellings() {
        #expect(spell("ng", "ươi", .grave) == "người")
        #expect(spell("v", "iêt", .dot) == "việt")
        #expect(spell("h", "oa", .grave) == "hòa")
        #expect(spell("h", "oa", .grave, .modern) == "hoà")
        #expect(spell("", "uy", .hook) == "ủy")
        #expect(spell("", "uy", .hook, .modern) == "uỷ")
        #expect(spell("kh", "oe", .hook, .modern) == "khoẻ")
        #expect(spell("qu", "y", .acute) == "quý")
        #expect(spell("qu", "y", .acute, .modern) == "quý")
        #expect(spell("gi", "ưa", .tilde) == "giữa")
        #expect(spell("g", "in", .grave) == "gìn")
        #expect(spell("s", "ooc", .acute) == "soóc")
        #expect(spell("kh", "uyu", .hook) == "khuỷu")
        #expect(spell("ng", "oeo", .dot) == "ngoẹo")
        #expect(spell("kh", "uya", .level) == "khuya")
        #expect(spell("gi", "êc", .acute) == "giếc")
        #expect(spell("th", "y", .level) == "thy")
    }

    @Test func openUoDisplayAndCommit() {
        // ENG-R531, ENG-R532: shown as ươ while typing, committed as uơ; tone on ơ in both.
        #expect(spell("th", "uơ", .hook, .traditional, .lowercase, .display) == "thưở")
        #expect(spell("th", "uơ", .hook) == "thuở")
        #expect(spell("h", "uơ", .level, .traditional, .lowercase, .display) == "hươ")
        #expect(spell("h", "uơ", .level) == "huơ")
        #expect(spell("h", "ương", .level, .traditional, .lowercase, .display) == "hương")
    }

    @Test func casing() {
        #expect(spell("đ", "a", .grave, .traditional, .titlecase) == "Đà")
        #expect(spell("ng", "ươi", .grave, .traditional, .uppercase) == "NGƯỜI")
        #expect(spell("", "ăn", .level, .traditional, .titlecase) == "Ăn")
        #expect(spell("t", "iêng", .acute, .traditional, .uppercase) == "TIẾNG")
    }

    @Test func agreesWithEnginePlacementForEveryTierASyllable() {
        // Two independent implementations of 5.1 (oracle over Characters, engine over Letter codes).
        for pair in SyllableTables.standardPairs {
            for tone in pair.tones {
                for style in [ToneStyle.traditional, .modern] {
                    let oracle = spell(pair.onset.spelling, pair.rhyme.spelling, tone, style)
                    #expect(oracle == placed(pair.spelling, tone, style), "\(pair.spelling) \(tone) \(style)")
                }
            }
        }
    }

    @Test func outputIsPrecomposedAndValid() {
        // ENG-R102: only precomposed letters; every committed Tier A spelling is Tier A again.
        for pair in SyllableTables.standardPairs {
            for tone in pair.tones {
                let text = spell(pair.onset.spelling, pair.rhyme.spelling, tone, .traditional, .uppercase)
                #expect(text.unicodeScalars.allSatisfy { $0.properties.canonicalCombiningClass == .notReordered })
                #expect(text.unicodeScalars.count == text.count)
                #expect(Orthography.validity(of: text) == .standard, "\(text)")
            }
        }
    }
}
