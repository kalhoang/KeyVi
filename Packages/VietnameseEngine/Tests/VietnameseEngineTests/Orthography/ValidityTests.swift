// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// Validity tiers (3.12) through the public `Orthography.validity(of:)` (ENG-R1212).
@Suite("Validity tiers (3.10 to 3.12)")
struct ValidityTests {
    @Test(arguments: [
        // Ordinary words and the 3.7 examples.
        "việt", "tiếng", "được", "người", "không", "chào", "của", "mía", "khuya", "khuyên", "yêu", "ỉa", "uống",
        "khuỷu", "ngoẹo", "boong", "soóc", "huýt", "tuýp", "huynh", "oà", "òa", "ủy", "uỷ",
        // gi and qu (3.8, 3.9, ENG-R304 to ENG-R307).
        "gì", "gìn", "gỉ", "già", "giữ", "giúp", "giỏi", "giấy", "giết", "giũa", "giuộc", "giường", "giếng",
        "giêng", "giếc", "quý", "quí", "quít", "quýt", "quốc", "quở", "quạu", "quỳnh", "quyết", "quệch",
        // ENG-R314 open y; ENG-R315 uơ; REG-08 names and rare rhymes.
        "ý", "hy", "kỹ", "lý", "mỹ", "sỹ", "tỷ", "Thy", "Vy", "kĩ", "lí", "mĩ", "huơ", "thuở", "huých", "huỵch",
        "tọe", "pía", "pin", "Buôn", "Ma", "Thuột", "Pắc",
        // REG-29: valid Tier A although absent from dictionaries.
        "hẹo",
        // Case does not matter (ENG-R332).
        "VIỆT", "NGƯỜI", "Đà",
    ])
    func standard(_ word: String) {
        #expect(Orthography.validity(of: word) == .standard)
    }

    @Test(arguments: [
        // 3.12 names and loans: clusters, k coda with any tone, k before any vowel.
        "Krông", "Đắk", "Đăk", "Lắk", "Búk", "Kon", "Kạn", "Plông", "Grai", "Đrắk", "Pắk", "Prông",
        // Labial + medial loans, gi + o-medial, open y after any onset, uơ after any onset.
        "buýt", "phuy", "voan", "gioăng", "chy", "ghy", "luơ",
        // Tier B extra rhymes, qu + o / ơn, teencode z, colloquial dz (REG-28).
        "ừm", "quọ", "quởn", "zá", "zui", "zậy", "dzô", "dzậy", "dzui", "dzữ", "dzìa", "Dzui", "hok", "oao",
    ])
    func extended(_ word: String) {
        #expect(Orthography.validity(of: word) == .extended)
    }

    @Test(arguments: [
        // REG-26: misspellings that must not be accepted (B044, B045).
        "nghãi", "nghô", "nghai", "ngha",
        // ENG-R310 to ENG-R313.
        "ci", "ky" + "a", "ge", "gha", "nge", "ngi", "cuân", "kuy", "ghoa", "giy", "giuy", "iêu", "tyêm", "qa", "quu",
        // ENG-R317: open ươ is never valid committed text.
        "thươ", "hươ", "ươ",
        // ENG-R320: stop codas take only sắc and nặng.
        "càc", "cảp", "hõt", "tẽt",
        // Not syllables: impossible onsets and codas, leftovers, several tones, non-letters.
        "fa", "ja", "wa", "mother", "text", "user", "ủe", "áá", "a1", "", " ", "chưâ", "hoê",
        // `ei` is no rhyme in any tier, so the place name `Glei` (3.3) is typed as is and restored to itself.
        "Glei",
    ])
    func invalid(_ word: String) {
        #expect(Orthography.validity(of: word) == .invalid)
    }

    @Test func decomposedInputIsAccepted() {
        #expect(Orthography.validity(of: "vie\u{0323}\u{0302}t") == .standard)
        #expect(Orthography.validity(of: "vie\u{0302}\u{0323}t") == .standard)
        #expect(Orthography.validity(of: "d\u{0323}") == .invalid)  // a tone on a consonant
        #expect(Orthography.validity(of: "a\u{0301}\u{0300}") == .invalid)  // two tones on one letter
        #expect(Orthography.validity(of: "a\u{0306}\u{0302}") == .invalid)  // two modifiers
        #expect(Orthography.validity(of: "c\u{0327}a") == .invalid)  // a mark that is not Vietnamese
    }

    @Test func everyToneOfEveryInventorySyllable() {
        for pair in SyllableTables.extendedPairs {
            for tone in Tone.allTones {
                let expected: Validity = pair.rhyme.accepts(tone) ? pair.tier : .invalid
                #expect(SyllableTables.validity(of: pair.letters, tone: tone) == expected, "\(pair.spelling) \(tone)")
            }
        }
    }
}
