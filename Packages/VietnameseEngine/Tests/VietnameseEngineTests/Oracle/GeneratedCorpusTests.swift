// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The generated corpus of ENG-T02 / ENG-T03 (key sequences and expected text; running the engine
/// over it belongs to the composition tests).
@Suite("Generated corpus (ENG-T02, ENG-T03)")
struct GeneratedCorpusTests {
    private func keys(_ onset: String, _ rhyme: String, _ tone: Tone, _ method: CorpusMethod, _ order: CorpusOrder)
        -> String?
    {
        KeySequenceGenerator.keys(onset: onset, rhyme: rhyme, tone: tone, method: method, order: order)
    }

    @Test func caseCounts() {
        let counts = GeneratedCorpus.counts()
        print("[ENG-T04] O1-O4 cases: \(counts.orders) (spec 237,824)")
        print(
            "[ENG-T04] ENG-T03 variant cases: \(counts.variants) (Titlecase and all caps per toned syllable, uwow per toned ươ syllable)"
        )
        // 15,406 toned syllables, of which 2,169 level: 4 x (3 x 2,169 + 4 x 13,237).
        #expect(counts.orders == 237_824)
        // The reference model's 237,916 counts the 92 cases of the `giu` duplicate (spec 3.15).
        #expect(counts.orders + 92 == 237_916)
        #expect(counts.variants == 2 * 15_406 + 864)
    }

    @Test func telexOrders() {
        #expect(keys("ng", "ươi", .grave, .telex, .o1) == "nguowif")
        #expect(keys("ng", "ươi", .grave, .telex, .o2) == "nguowif")
        #expect(keys("ng", "ươi", .grave, .telex, .o3) == "nguoiwf")
        #expect(keys("ng", "ươi", .grave, .telex, .o4) == "ngufowi")
        #expect(keys("đ", "ươc", .dot, .telex, .o1) == "dduowcj")
        #expect(keys("đ", "ươc", .dot, .telex, .o2) == "dduowjc")
        #expect(keys("đ", "ươc", .dot, .telex, .o3) == "duocdwj")
        #expect(keys("đ", "ươc", .dot, .telex, .o4) == "ddujowc")
        #expect(keys("c", "ân", .grave, .telex, .o1) == "caanf")  // W034
        #expect(keys("c", "ân", .grave, .telex, .o2) == "caafn")  // W035
        #expect(keys("c", "ân", .grave, .telex, .o3) == "canaf")
        #expect(keys("v", "iêt", .dot, .telex, .o1) == "vieetj")  // W014
        #expect(keys("kh", "ông", .level, .telex, .o1) == "khoong")  // W019
        #expect(keys("kh", "ông", .level, .telex, .o4) == nil)
        #expect(keys("qu", "y", .acute, .telex, .o4) == "quys")
        #expect(keys("gi", "ưa", .tilde, .telex, .o4) == "giuwxa")
        #expect(keys("th", "uơ", .hook, .telex, .o1) == "thuowr")  // W083
    }

    @Test func telexLiteralOoNeedsTheEscape() {
        // ENG-T02: `booong` -> `boong`.
        #expect(keys("b", "oong", .level, .telex, .o1) == "booong")  // W092
        #expect(keys("s", "ooc", .acute, .telex, .o1) == "sooocs")  // W090
        #expect(keys("s", "ooc", .acute, .telex, .o2) == "sooosc")
        #expect(keys("s", "ooc", .acute, .telex, .o3) == "sooocs")
        #expect(keys("s", "ooc", .acute, .telex, .o4) == "sosooc")
        #expect(keys("s", "ooc", .acute, .vni, .o1) == "sooc1")
        #expect(keys("s", "ooc", .acute, .vni, .o4) == "so1oc")
    }

    @Test func vniOrders() {
        #expect(keys("đ", "ươc", .dot, .vni, .o1) == "d9uo7c5")  // W175
        #expect(keys("đ", "ươc", .dot, .vni, .o2) == "d9uo75c")
        #expect(keys("đ", "ươc", .dot, .vni, .o3) == "duoc975")
        #expect(keys("đ", "ươc", .dot, .vni, .o4) == "d9u5o7c")
        #expect(keys("v", "iêt", .dot, .vni, .o1) == "vie6t5")  // W170
        #expect(keys("v", "iêt", .dot, .vni, .o2) == "vie65t")  // W169
        #expect(keys("", "ăn", .level, .vni, .o3) == "an8")
        #expect(keys("h", "oa", .grave, .vni, .o1) == "hoa2")  // W178
    }

    @Test func variants() {
        func variant(_ onset: String, _ rhyme: String, _ tone: Tone, _ kind: CorpusVariant) -> String? {
            KeySequenceGenerator.variantKeys(onset: onset, rhyme: rhyme, tone: tone, variant: kind)
        }
        #expect(variant("đ", "a", .grave, .titlecase) == "Ddaf")  // W204
        #expect(variant("đ", "a", .grave, .uppercase) == "DDAF")
        #expect(variant("v", "iêt", .dot, .titlecase) == "Vieetj")  // W201
        #expect(variant("v", "iêt", .dot, .uppercase) == "VIEETJ")  // W202
        #expect(variant("ng", "ươi", .grave, .explicitUwow) == "nguwowif")  // W018
        #expect(variant("đ", "ươc", .dot, .explicitUwow) == "dduwowcj")  // W017
        #expect(variant("ng", "ươi", .grave, .uppercase) == "NGUOWIF")
        #expect(variant("th", "uơ", .hook, .explicitUwow) == nil)
        #expect(variant("b", "a", .level, .explicitUwow) == nil)
    }

    @Test func casesCarryOracleExpectations() {
        var found: GeneratedCase?
        var methods = Set<CorpusMethod>()
        var kinds = Set<GeneratedCase.Kind>()
        GeneratedCorpus.forEachOrderCase { generated in
            methods.insert(generated.method)
            kinds.insert(generated.kind)
            if generated.onset == "th", generated.rhyme == "uơ", generated.tone == .hook, generated.method == .telex,
                generated.style == .traditional, generated.kind == .order(.o1)
            {
                found = generated
            }
        }
        #expect(methods == Set(CorpusMethod.allCases))
        #expect(kinds == Set(CorpusOrder.allCases.map { GeneratedCase.Kind.order($0) }))
        #expect(found != nil)
        let thuo = found
        #expect(thuo?.keys == "thuowr")
        #expect(thuo?.expectedDisplay == "thưở")
        #expect(thuo?.expectedCommitted == "thuở")
        #expect(thuo?.events.count == 6)
        #expect(
            thuo?.configuration
                == EngineConfiguration(
                    inputMethod: .telex(TelexOptions()), toneStyle: .traditional, typoCorrection: false))
    }

    @Test func variantCasesUseTraditionalTelex() {
        var titlecased = 0
        GeneratedCorpus.forEachVariantCase { generated in
            #expect(generated.method == .telex && generated.style == .traditional)
            if generated.kind == .variant(.titlecase) {
                titlecased += 1
                #expect(generated.keys.first?.isUppercase == true)
                #expect(generated.expectedCommitted.first?.isUppercase == true)
            }
        }
        #expect(titlecased == 15_406)
    }

    @Test func keysUseOnlyTheMethodsAlphabet() {
        // ENG-R403: Telex sequences are letters only; VNI sequences are letters and digits.
        GeneratedCorpus.forEachOrderCase { generated in
            let allowed: (Character) -> Bool =
                generated.method == .telex
                ? { $0.isASCII && $0.isLetter } : { $0.isASCII && ($0.isLetter || $0.isNumber) }
            #expect(generated.keys.allSatisfy(allowed), "\(generated.keys)")
        }
    }
}
