// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-T12: the spot list stays unchanged after commit with default options in any context (no previous
/// token, a Vietnamese run, an English run; general and code app contexts), with the 13.9 fixture
/// resources, which contain every spot word that needs data. `SpotListGateTests` runs the same list and
/// contexts (`SpotList`) on the bundled data.
///
/// Which words depend on data:
/// - none: `text user case wifi USB data verbose` (L5, invalid syllables), `mother keyboard startup
///   facebook java year` (L0, literal before any transform);
/// - the English lexicon or the tech-always list (`R is English`): `password traffic boss coffee less
///   tomorrow www` (L4, escape used), `plans grows ask zoom two wow` (L6, Tier B only);
/// - the lexicon and the attested-syllable data or an `en` ambiguity row: `does` (`dóe` is a valid Tier A
///   syllable; the fixtures leave it unattested so L8 restores it; with real data, if `dóe` is attested,
///   `does` needs an `en` row of the ambiguity table or it is kept as `dóe` outside English runs).
@Suite("ENG-T12 spot list")
struct SpotListTests {
    static let needsNoData: Set<String> = [
        "text", "user", "case", "wifi", "USB", "data", "verbose", "mother", "keyboard", "startup", "facebook", "java",
        "year",
    ]

    @Test func listIsTheSpecs() {
        #expect(SpotList.words.count == 27)
        #expect(Set(SpotList.words).isSuperset(of: Self.needsNoData))
    }

    @Test(arguments: SpotList.words)
    func unchangedInAnyContext(word: String) throws {
        let failures = try SpotList.failures(words: [word], resources: Committing.fixtures)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test(arguments: needsNoData.sorted())
    func unchangedWithoutAnyData(word: String) throws {
        #expect(try Committing.text(word + " ", resources: .empty) == word + " ")
    }
}
