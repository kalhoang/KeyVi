// SPDX-License-Identifier: MPL-2.0

/// The rhyme lists of spec/01-engine.md section 3, transcribed in the spec's order. These lists are
/// the only hand-written orthography data; every derived structure (validity table, viability
/// automaton, counts) is generated from them and the rules in `SyllableRules` (ENG-R302, ENG-R346).
package enum RhymeInventory {
    /// 3.7, Tier A rhymes as written after an ordinary consonant onset, grouped by nucleus (156).
    package static let standardGroups: [(nucleus: String, rhymes: [String])] = [
        ("a", ["a", "ac", "ach", "ai", "am", "an", "ang", "anh", "ao", "ap", "at", "au", "ay"]),
        ("medial o + a", ["oa", "oac", "oach", "oai", "oam", "oan", "oang", "oanh", "oat", "oay"]),
        ("ă", ["ăc", "ăm", "ăn", "ăng", "ăp", "ăt"]),
        ("medial o + ă", ["oăc", "oăm", "oăn", "oăng", "oăt"]),
        ("â", ["âc", "âm", "ân", "âng", "âp", "ât", "âu", "ây"]),
        ("medial u + â", ["uân", "uâng", "uât", "uây"]),
        ("e", ["e", "ec", "em", "en", "eng", "eo", "ep", "et"]),
        ("medial o + e", ["oe", "oen", "oeo", "oet"]),
        ("ê", ["ê", "êch", "êm", "ên", "ênh", "êp", "êt", "êu"]),
        ("medial u + ê", ["uê", "uêch", "uênh"]),
        ("i", ["i", "ich", "im", "in", "inh", "ip", "it", "iu"]),
        ("y (open)", ["y"]),
        ("medial u + y", ["uy", "uych", "uyn", "uynh", "uyp", "uyt", "uyu"]),
        ("iê / ia", ["ia", "iêc", "iêm", "iên", "iêng", "iêp", "iêt", "iêu"]),
        ("yê (no onset only)", ["yêm", "yên", "yêng", "yêt", "yêu"]),
        ("medial u + iê", ["uya", "uyên", "uyêt"]),
        ("o", ["o", "oc", "oi", "om", "on", "ong", "op", "ot"]),
        ("oo (loans)", ["ooc", "oong"]),
        ("ô", ["ô", "ôc", "ôi", "ôm", "ôn", "ông", "ôp", "ôt"]),
        ("ơ", ["ơ", "ơi", "ơm", "ơn", "ơp", "ơt"]),
        ("medial u + ơ", ["uơ"]),
        ("u", ["u", "uc", "ui", "um", "un", "ung", "up", "ut"]),
        ("uô / ua", ["ua", "uôc", "uôi", "uôm", "uôn", "uông", "uôt"]),
        ("ư", ["ư", "ưc", "ưi", "ưng", "ưt", "ưu"]),
        ("ươ / ưa", ["ưa", "ươc", "ươi", "ươm", "ươn", "ương", "ươp", "ươt", "ươu"]),
    ]

    /// 3.7 flattened (156 rhymes).
    package static let standard: [String] = standardGroups.flatMap(\.rhymes)

    /// 3.8, rhymes after `qu`, written without the medial glide (41 rhymes).
    package static let afterQu: [String] = [
        "a", "ac", "ach", "ai", "an", "ang", "anh", "ao", "at", "au", "ay",
        "ăc", "ăm", "ăn", "ăng", "ăp", "ăt",
        "ân", "âng", "ât", "ây",
        "e", "en", "eo", "et",
        "ê", "êch", "ên", "ênh", "êt", "êu",
        "i", "it", "y", "ych", "ynh", "yt", "yên", "yêt",
        "ơ", "ôc",
    ]

    /// 3.8, Tier B rhymes after `qu`: `quọ`, `quởn`.
    package static let afterQuExtended: [String] = ["o", "ơn"]

    /// ENG-R305, the rhymes `gi + iêc` and `gi + iêng` written after the `gi` onset (`giếc`, `giếng`).
    package static let afterGiExtra: [String] = ["êc", "êng"]

    /// 3.12, extra Tier B rhymes after ordinary onsets.
    package static let extendedExtra: [String] = [
        "oao", "oap", "oăp", "oem", "oeng", "oec", "oep", "uên", "uêt", "uêu", "ưm", "ưn", "ưp",
    ]

    /// ENG-R314, onsets after which the open rhyme `y` is Tier A (`ý hy kỹ lý mỹ sỹ tỷ Thy Vy`).
    package static let openYStandardOnsets: Set<Onset> = [.none, .h, .k, .l, .m, .s, .t, .th, .v]

    /// ENG-R315, onsets after which `uơ` is Tier A (`huơ`, `thuở`).
    package static let uoStandardOnsets: Set<Onset> = [.h, .th]
}
