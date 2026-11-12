// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The resources that spec 13.9 prescribes for the commit-decision examples (B001-B064). The word
/// lists are copied from the 13.9 fixture paragraph and the ENG-R821 proposal table; a test checks
/// them against `commit-fixtures.tsv`, which the extractor reads from the spec.
public enum SpecFixtures {
    /// 13.9: the English lexicon of the fixtures.
    public static let englishLexicon: [String] = """
        test this these there best max list been text user wifi usb case password traffic boss coffee as is was \
        has its us car did theme does door her post says war two wow ask task zoom more year mother keyboard \
        verbose startup data plans grows www less tomorrow the and you a i cost room tar class
        """.split(separator: " ").map(String.init)

    /// 13.9: the tech-always list.
    public static let techAlways: [String] = ["www", "wifi", "usb"]

    /// 13.9: the code-only tech list.
    public static let techCodeOnly: [String] = ["tar"]

    /// 13.9: the Tier A syllables that are not attested.
    public static let unattestedSyllables: [String] = ["dóe", "hẻ", "dổ", "pót", "sáy", "ửa", "tơn", "dơn"]

    /// ENG-R821: the proposed ambiguity rows (raw keys, display, decision).
    public static let ambiguityProposals: [(raw: String, display: String, language: Language)] = [
        ("as", "á", .vietnamese), ("is", "í", .english), ("was", "ứa", .english), ("has", "há", .vietnamese),
        ("its", "ít", .vietnamese), ("this", "thí", .vietnamese), ("these", "thế", .vietnamese),
        ("there", "thể", .vietnamese), ("been", "bên", .vietnamese), ("car", "cả", .vietnamese),
        ("test", "tét", .english), ("best", "bét", .english), ("list", "lít", .english), ("cost", "cót", .english),
        ("room", "rôm", .english), ("did", "đi", .vietnamese), ("theme", "thêm", .vietnamese),
        ("max", "mã", .vietnamese),
    ]

    /// Every Tier A toned syllable in lowercase, committed form (`thuở`), in both tone styles (so
    /// `hòa` and `hoà` are both present), spelled by the oracle from the engine's tables. Computed once.
    public static let allStandardSyllables: Set<String> = {
        var result = Set<String>()
        for pair in SyllableTables.standardPairs {
            for tone in pair.tones {
                for style in [ToneStyle.traditional, .modern] {
                    result.insert(
                        SyllableOracle.spell(
                            onset: pair.onset.spelling, rhyme: pair.rhyme.spelling, tone: tone, style: style))
                }
            }
        }
        return result
    }()

    /// 13.9: every Tier A syllable is attested except `unattestedSyllables`. Lowercase; commit rules
    /// look up the lowercased committed display.
    public static let attestedSyllables: Set<String> = allStandardSyllables.subtracting(unattestedSyllables)

    /// The 13.9 resources, with optional user lists and macros for tests that need them.
    public static func commitResources(
        userKeepRaw: [String] = [], userKeepVietnamese: [String] = [], macros: MacroTable = .empty
    ) -> Resources {
        Resources(
            english: WordSet(englishLexicon), techAlways: WordSet(techAlways), techCodeOnly: WordSet(techCodeOnly),
            attestedSyllables: WordSet(attestedSyllables),
            ambiguity: Dictionary(uniqueKeysWithValues: ambiguityProposals.map { ($0.raw, $0.language) }),
            userKeepRaw: WordSet(userKeepRaw), userKeepVietnamese: WordSet(userKeepVietnamese), macros: macros)
    }
}
