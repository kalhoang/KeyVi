// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// Spec 5.1 to 5.4 as pure placement over letters (ENG-R501).
@Suite("Tone placement (5.1, 5.2)")
struct TonePlacementTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let keys: String
        let letters: String
        let tone: Tone
        let traditional: String
        let modern: String
        var testDescription: String { keys }
    }

    /// The table of 5.3 (keys shown for reference; placement is applied to the final letters).
    static let table53: [Row] = [
        Row(keys: "hoaf", letters: "hoa", tone: .grave, traditional: "hòa", modern: "hoà"),
        Row(keys: "hoafn", letters: "hoan", tone: .grave, traditional: "hoàn", modern: "hoàn"),
        Row(keys: "khoer", letters: "khoe", tone: .hook, traditional: "khỏe", modern: "khoẻ"),
        Row(keys: "thuyr", letters: "thuy", tone: .hook, traditional: "thủy", modern: "thuỷ"),
        Row(keys: "huyts", letters: "huyt", tone: .acute, traditional: "huýt", modern: "huýt"),
        Row(keys: "huynhf", letters: "huynh", tone: .grave, traditional: "huỳnh", modern: "huỳnh"),
        Row(keys: "xoays", letters: "xoay", tone: .acute, traditional: "xoáy", modern: "xoáy"),
        Row(keys: "hoaif", letters: "hoai", tone: .grave, traditional: "hoài", modern: "hoài"),
        Row(keys: "khuyur", letters: "khuyu", tone: .hook, traditional: "khuỷu", modern: "khuỷu"),
        Row(keys: "ngoeoj", letters: "ngoeo", tone: .dot, traditional: "ngoẹo", modern: "ngoẹo"),
        Row(keys: "cuar", letters: "cua", tone: .hook, traditional: "của", modern: "của"),
        Row(keys: "mias", letters: "mia", tone: .acute, traditional: "mía", modern: "mía"),
        Row(keys: "muwaf", letters: "mưa", tone: .grave, traditional: "mừa", modern: "mừa"),
        Row(keys: "tuooir", letters: "tuôi", tone: .hook, traditional: "tuổi", modern: "tuổi"),
        Row(keys: "ruwowuj", letters: "rươu", tone: .dot, traditional: "rượu", modern: "rượu"),
        Row(keys: "hieeur", letters: "hiêu", tone: .hook, traditional: "hiểu", modern: "hiểu"),
        Row(keys: "khuyeenr", letters: "khuyên", tone: .hook, traditional: "khuyển", modern: "khuyển"),
        Row(keys: "hueej", letters: "huê", tone: .dot, traditional: "huệ", modern: "huệ"),
        Row(keys: "quys", letters: "quy", tone: .acute, traditional: "quý", modern: "quý"),
        Row(keys: "giuwax", letters: "giưa", tone: .tilde, traditional: "giữa", modern: "giữa"),
        Row(keys: "sooocs", letters: "sooc", tone: .acute, traditional: "soóc", modern: "soóc"),
    ]

    @Test(arguments: table53)
    func placementTable(_ row: Row) {
        #expect(placed(row.letters, row.tone, .traditional) == row.traditional)
        #expect(placed(row.letters, row.tone, .modern) == row.modern)
    }

    @Test func relocationWhileTyping() {
        // 5.4: the position is recomputed from the letters each time.
        #expect(placed("hoa", .grave) == "hòa")
        #expect(placed("hoa", .grave, .modern) == "hoà")
        #expect(placed("hoan", .grave) == "hoàn")
        #expect(placed("gi", .acute) == "gí")
        #expect(placed("giu", .acute) == "giú")
        #expect(placed("giup", .acute) == "giúp")
    }

    @Test func quAndGiOnsetsAgreeInBothStyles() {
        // ENG-R502.
        for (spelling, tone, expected) in [
            ("quy", Tone.acute, "quý"), ("qua", .hook, "quả"), ("quơ", .hook, "quở"), ("gia", .grave, "già"),
            ("giưa", .tilde, "giữa"), ("giua", .tilde, "giũa"), ("giêng", .acute, "giếng"),
        ] {
            #expect(placed(spelling, tone, .traditional) == expected)
            #expect(placed(spelling, tone, .modern) == expected)
        }
    }

    @Test func article82TwoLetterNuclei() {
        // ENG-R511: first letter of ia ua ưa, second of iê yê uô uơ.
        #expect(placed("bia", .grave) == "bìa")
        #expect(placed("lua", .dot) == "lụa")
        #expect(placed("lưa", .hook) == "lửa")
        #expect(placed("biên", .hook) == "biển")
        #expect(placed("thuyên", .grave) == "thuyền")
        #expect(placed("nhuôm", .dot) == "nhuộm")
        #expect(placed("thuơ", .hook) == "thuở")
        #expect(placed("thươ", .hook) == "thưở")  // display form while typing (W083)
    }

    @Test func nonSyllablesStillGetADeterministicPosition() {
        #expect(placed("cae", .acute) == "cáe")  // W215 `case`
        #expect(placed("tet", .tilde) == "tẽt")  // W211 `text`
        #expect(placed("ue", .hook) == "ủe")  // W212 `user`
        #expect(placed("ưii", .grave) == "ừii")  // W213 `wifi`
        #expect(placed("ub", .acute) == "úb")  // W214 `USB`
        #expect(placed("oaio", .acute) == "oáio")  // four letters: the second
        #expect(TonePlacement.toneOffset(in: letters("qu"), style: .traditional) == nil)  // ENG-R410
        #expect(TonePlacement.toneOffset(in: letters("tr"), style: .traditional) == nil)
    }

    @Test func stylesDifferOnlyForOpenOaOeUy() {
        // 5.2: the three open pairs are the only difference between the styles.
        for pair in SyllableTables.standardPairs {
            let letters = pair.letters
            let traditional = TonePlacement.toneOffset(in: letters, style: .traditional)
            let modern = TonePlacement.toneOffset(in: letters, style: .modern)
            let styled = ["oa", "oe", "uy"].contains(pair.rhyme.spelling)
            #expect((traditional != modern) == styled, "\(pair.spelling)")
        }
    }
}
