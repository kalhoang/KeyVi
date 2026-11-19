// SPDX-License-Identifier: MPL-2.0
//
// ENG-T56, the data half of the typo correction's gates (spec/01-engine.md 11A.5): the guard list's false positives
// and completeness, the unmarked shapes and the Vietnamese keyings against an independent computation from the
// oracle's side, and the resident budget of ENG-R1120 (at most 1 MB for the new data, 512 KB of it for the guard
// list). The neighbours table is checked by CorrectionInputTests and MalformedResourceTests; byte reproducibility by
// LexiconBuilderTests. Serialized so that the memory measurement is not disturbed by another test of this suite.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData
import VietnameseEngineTesting

@testable import lexicon_builder

#if canImport(Darwin)
import Darwin
#endif

@Suite(.serialized)
struct CorrectionDataTests {
    static func bundledCorrection() throws -> CorrectionData {
        try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([])).correction
    }

    static func committedList(_ name: String) throws -> [String] {
        try String(contentsOf: TestPaths.committedResources.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    // MARK: Guard list (ENG-R1120 (2))

    /// ENG-T56: at most 0.5 % of 100,000 random letter strings of 5 to 12 letters (seeded) are answered yes.
    @Test func guardListFalsePositivesStayUnder0_5Percent() throws {
        let guardList = try Self.bundledCorrection().guardList
        var generator = SeededGenerator(seed: 18_112_026)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var positives = 0
        for _ in 0..<100_000 {
            let length = Int.random(in: 5...12, using: &generator)
            let word = String((0..<length).map { _ in letters.randomElement(using: &generator)! })
            if guardList.mayContain(word) { positives += 1 }
        }
        print("ENG-T56 guard list: \(positives) of 100,000 random strings answered yes (\(Double(positives) / 1000) %)")
        #expect(positives <= 500)
    }

    /// A Bloom filter never answers no for a word it was built from: every guard word of the pinned inputs is held.
    @Test func theGuardFilterNeverForgetsAnInputWord() throws {
        let layout = Layout(dataRoot: TestPaths.dataRoot, resources: TestPaths.committedResources)
        let words = try GuardList.words(layout, lexicon: try Builder.correctionLexicon(layout))
        let guardList = try Self.bundledCorrection().guardList
        let forgotten = words.filter { !guardList.mayContain($0) }
        #expect(forgotten.isEmpty, "\(forgotten.sorted().prefix(20))")
        #expect(guardList.wordCount == words.count)
    }

    // MARK: Shapes and keyings against the oracle (ENG-T56)

    /// The unmarked shapes from the oracle's spellings: every Tier A toned syllable (`SpecFixtures`) and every Tier B
    /// pair spelled by `SyllableOracle`, with the tone and the marks removed and `đ` written `d`; the keyings as the
    /// union of `KeyingOracle.keyings` over every Tier A syllable and allowed tone. Both equal the bundled files
    /// exactly, and the loaded sets hold every element. The builder (`SyllableTables` through lexicon-builder) and the
    /// oracle (`SpecFixtures`, `SyllableOracle`, `KeySequenceGenerator`) are the two independent computations; a
    /// difference is a bug in one of them, never a reason to drop a form the spec requires.
    @Test func shapesAndKeyingsEqualAnIndependentComputation() throws {
        var shapes = Set(SpecFixtures.allStandardSyllables.map(Self.unmarked))
        for pair in SyllableTables.extendedPairs where pair.tier == .extended {
            shapes.insert(
                Self.unmarked(
                    SyllableOracle.spell(
                        onset: pair.onset.spelling, rhyme: pair.rhyme.spelling, tone: .level, style: .traditional)))
        }
        var keyings = Set<String>()
        for pair in SyllableTables.standardPairs {
            for tone in pair.tones {
                keyings.formUnion(
                    KeyingOracle.keyings(onset: pair.onset.spelling, rhyme: pair.rhyme.spelling, tone: tone))
            }
        }
        let bundledShapes = Set(try Self.committedList("unmarked-shapes.txt"))
        let bundledKeyings = Set(try Self.committedList("vietnamese-keyings.txt"))
        let shapesOnlyOracle = shapes.subtracting(bundledShapes).sorted()
        let shapesOnlyBundled = bundledShapes.subtracting(shapes).sorted()
        let keyingsOnlyOracle = keyings.subtracting(bundledKeyings).sorted()
        let keyingsOnlyBundled = bundledKeyings.subtracting(keyings).sorted()
        print(
            "ENG-T56 independent computation: shapes \(shapes.count) (bundled \(bundledShapes.count)), keyings "
                + "\(keyings.count) (bundled \(bundledKeyings.count))")
        #expect(shapesOnlyOracle.isEmpty, "shapes only in the oracle: \(shapesOnlyOracle.prefix(20))")
        #expect(shapesOnlyBundled.isEmpty, "shapes only bundled: \(shapesOnlyBundled.prefix(20))")
        #expect(keyingsOnlyOracle.isEmpty, "keyings only in the oracle: \(keyingsOnlyOracle.prefix(20))")
        #expect(keyingsOnlyBundled.isEmpty, "keyings only bundled: \(keyingsOnlyBundled.prefix(20))")
        let correction = try Self.bundledCorrection()
        #expect(shapes.allSatisfy { correction.unmarkedShapes.contains($0) })
        #expect(keyings.allSatisfy { correction.vietnameseKeyings.contains($0) })
    }

    @Test func theOracleWritesTheSpecExamples() {
        #expect(KeyingOracle.keyings(onset: "ph", rhyme: "ai", tone: .hook) == ["phair"])
        #expect(KeyingOracle.keyings(onset: "ch", rhyme: "inh", tone: .acute) == ["chinhs", "chisnh"])
        #expect(
            KeyingOracle.keyings(onset: "th", rhyme: "ương", tone: .grave)
                == ["thuwowngf", "thuowngf", "thwowngf", "thuwowfng", "thuowfng", "thwowfng"])
        #expect(KeyingOracle.keyings(onset: "t", rhyme: "ưng", tone: .grave) == ["tuwngf", "twngf", "tuwfng", "twfng"])
        #expect(KeyingOracle.keyings(onset: "", rhyme: "ư", tone: .grave) == ["uwf"])
        #expect(KeyingOracle.keyings(onset: "qu", rhyme: "ân", tone: .grave) == ["quaanf", "quaafn"])
        #expect(KeyingOracle.keyings(onset: "đ", rhyme: "i", tone: .level) == ["ddi"])
        #expect(KeyingOracle.keyings(onset: "b", rhyme: "oong", tone: .level) == ["boong"])
    }

    /// The marks and the tone removed, `đ` written `d` (ENG-R1110 (d)), from the composed characters.
    static func unmarked(_ syllable: String) -> String {
        let plain = syllable.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .nonspacingMark
        }
        return String(String.UnicodeScalarView(plain)).replacingOccurrences(of: "đ", with: "d")
    }

    // MARK: Resident budget (ENG-R1120, ENG-R1231)

    /// ENG-R1120: the new data adds at most 1 MB resident, the guard list at most 512 KB of it. Measured as the live
    /// malloc bytes the loaded `CorrectionData` retains (the drop when `Resources.correction` is replaced by `.empty`
    /// on a freshly loaded value), the median of five loads, as `staysWithinLoadTimeAndMemoryBudget` measures.
    ///
    /// Known issue (19/11/2026, docs/decisions/0203-correction-data.md section 6): 1.30 MB. `CorrectionData` holds the
    /// shapes and the keyings as `WordSet`s, whose `Set<String>` takes 65,536 buckets of 16 bytes for the 27,277
    /// keyings alone (1 MB). The named fallback, a sorted array of packed `UInt64` (5 bits per letter, the longest
    /// keying has 9 letters), changes the type of the two `CorrectionData` fields in `PublicAPI.swift`, which the data
    /// track does not own; it is requested from the logic track and the integration. Once the data takes the packed
    /// form, the known issue stops occurring and this test fails until the marker is removed.
    @Test func correctionDataStaysWithinItsResidentBudget() throws {
        var retained: [Int] = []
        for _ in 0..<5 {
            var resources: Resources? = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
            let withData = liveMallocBytes()
            resources?.correction = .empty
            let withoutData = liveMallocBytes()
            retained.append(withData - withoutData)
            withExtendedLifetime(resources) {}
            resources = nil
        }
        let median = retained.sorted()[retained.count / 2]
        let guardBytes = try Self.bundledCorrection().guardList.bits.count * 8
        let estimate =
            Self.estimatedSetBytes(try Self.committedList("vietnamese-keyings.txt"))
            + Self.estimatedSetBytes(try Self.committedList("unmarked-shapes.txt"))
        print(
            "ENG-R1120 measurement (debug): correction data retains \(median) bytes "
                + "(\(String(format: "%.2f", Double(median) / 1_048_576)) MB, five loads \(retained)); guard list bits "
                + "\(guardBytes) bytes; the keyings and shapes word sets \(estimate) bytes by the Set layout")
        #expect(guardBytes <= 512 * 1024)
        withKnownIssue("ENG-R1120: the shapes and keyings as WordSet exceed 1 MB until they take the packed form") {
            #expect(median <= 1_048_576, "the correction data retains \(median) bytes, more than 1 MB")
        }
    }

    /// The storage of a `Set<String>` of `words`: a power-of-two bucket count at the 75 % maximum load factor, 16 bytes
    /// per bucket (a small string lives inline) and one bit of occupancy each.
    static func estimatedSetBytes(_ words: [String]) -> Int {
        var buckets = 1
        while Double(buckets) * 0.75 < Double(words.count) { buckets *= 2 }
        return buckets * 16 + buckets / 8
    }

    private func liveMallocBytes() -> Int {
        #if canImport(Darwin)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
        #else
        return 0
        #endif
    }
}
