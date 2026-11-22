// SPDX-License-Identifier: MPL-2.0
//
// ENG-T12 with the bundled data: the 27 spot words, typed in Telex with default options and committed by
// a space, with no previous token, after a Vietnamese token and after an English token, in the general
// and code app contexts. The other real-data gates do not cover the no-previous-token case or the code
// context, and accept any change that a `vi` ambiguity row explains, so a hand edit of the data (a `vi`
// row for `does` plus an attested `dóe`) would otherwise change a spot word with every test passing.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T12 spot list with the bundled data")
struct SpotListGateTests {
    @Test("Every spot word is unchanged after commit in every context")
    func unchangedInAnyContext() throws {
        let failures = try SpotList.failures(resources: try RealData.resources())
        print("[ENG-T12] \(SpotList.words.count) words, \(failures.count) changed:\n" + RealData.listing(failures))
        #expect(failures.isEmpty, "changed:\n\(RealData.listing(failures))")
    }

    @Test("The seeds stand for the contexts they name with the bundled data")
    func seedsGiveTheirContexts() throws {
        let resources = try RealData.resources()
        // ENG-R823: `việt` is a vi token, so the run is not English; `and` is an English word that is not
        // a Vietnamese syllable, so the run after it is English.
        var driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false), resources: resources)
        try driver.type("vieejt ")
        #expect(driver.field.string == "việt " && !driver.state.recentLanguages.isEnglishRun)
        driver = EngineDriver(configuration: EngineConfiguration(typoCorrection: false), resources: resources)
        try driver.type("and ")
        #expect(driver.field.string == "and " && driver.state.recentLanguages.isEnglishRun)
        #expect(SpotList.seeds == ["", "vieejt ", "and "])
    }

    @Test("The gate catches a data edit that composes a spot word")
    func gateCatchesADataEdit() throws {
        // The edit of the review: `does` decided vi and `dóe` attested. Outside an English run L11 keeps
        // `dóe`; in an English run L10 still restores `does`.
        var resources = try RealData.resources()
        resources.ambiguity["does"] = .vietnamese
        resources.attestedSyllables = WordSet(SpecFixtures.allStandardSyllables)
        let failures = try SpotList.failures(words: ["does"], resources: resources)
        #expect(failures.contains { $0.seed.isEmpty && $0.committed == "dóe " })
        #expect(failures.allSatisfy { $0.seed != "and " })
    }
}
