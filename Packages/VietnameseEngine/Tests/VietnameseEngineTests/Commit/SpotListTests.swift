// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-T12: the spot list stays unchanged after commit with default options in any context (no previous
/// token, a Vietnamese run, an English run; general and code app contexts), with the 13.9 fixture
/// resources, which contain every spot word that needs data.
///
/// Which words depend on data (to re-check once `VietnameseEngineData` ships the real lists):
/// - none: `text user case wifi USB data verbose` (L5, invalid syllables), `mother keyboard startup
///   facebook java year` (L0, literal before any transform);
/// - the English lexicon or the tech-always list (`R is English`): `password traffic boss coffee less
///   tomorrow www` (L4, escape used), `plans grows ask zoom two wow` (L6, Tier B only);
/// - the lexicon and the attested-syllable data or an `en` ambiguity row: `does` (`dóe` is a valid Tier A
///   syllable; the fixtures leave it unattested so L8 restores it; with real data, if `dóe` is attested,
///   `does` needs an `en` row of the ambiguity table or it is kept as `dóe` outside English runs).
@Suite("ENG-T12 spot list")
struct SpotListTests {
    static let words = """
        text user case wifi USB data verbose password traffic boss coffee less tomorrow mother keyboard startup \
        facebook java year plans grows ask zoom two wow does www
        """.split(separator: " ").map(String.init)

    static let needsNoData: Set<String> = [
        "text", "user", "case", "wifi", "USB", "data", "verbose", "mother", "keyboard", "startup", "facebook", "java",
        "year",
    ]

    @Test func listIsTheSpecs() {
        #expect(Self.words.count == 27)
    }

    @Test(arguments: words)
    func unchangedInAnyContext(word: String) throws {
        for seed in ["", "vieejt ", "and "] {
            for context in [AppContext.general, .code] {
                let configuration = EngineConfiguration(appContext: context)
                let text = try Committing.text(seed + word + " ", configuration)
                let seedText = try Committing.text(seed, configuration)
                #expect(text == seedText + word + " ", "\(word) after \(seed.debugDescription) in \(context)")
            }
        }
    }

    @Test(arguments: needsNoData.sorted())
    func unchangedWithoutAnyData(word: String) throws {
        #expect(try Committing.text(word + " ", resources: .empty) == word + " ")
    }
}
