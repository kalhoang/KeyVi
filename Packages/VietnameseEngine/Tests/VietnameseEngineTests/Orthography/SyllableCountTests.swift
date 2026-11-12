// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// ENG-R350: the generator prints its own counts; differences from spec 3.15 are explained in
/// docs/decisions/0100-engine-syllable-counts.md.
@Suite("Syllable inventory counts (ENG-R350)")
struct SyllableCountTests {
    /// Pairs the spec's reference model counts twice: the spelling `giu` is generated both as `g` +
    /// `iu` and as `gi` + `u`, but 3.13 parses it only as `gi` + `u` (ENG-R305, ENG-R306).
    static let modelDuplicatePairs = [("g", "iu")]
    static let modelDuplicateTonedSyllables = 6  // `iu` takes all six tones

    @Test func rhymeCounts() {
        let standard = RhymeInventory.standard
        print(
            "[ENG-R350] Tier A rhymes: \(standard.count) (spec 156); qu rhymes: \(RhymeInventory.afterQu.count) (spec 41)"
        )
        #expect(standard.count == 156)
        #expect(Set(standard).count == 156)
        #expect(RhymeInventory.afterQu.count == 41)
        #expect(Set(RhymeInventory.afterQu).count == 41)
        #expect(RhymeInventory.extendedExtra.count == 13)
        // Group sizes as printed in the 3.7 table.
        #expect(
            RhymeInventory.standardGroups.map(\.rhymes.count) == [
                13, 10, 6, 5, 8, 4, 8, 4, 8, 3, 8, 1, 7, 8, 5, 3, 8, 2, 8, 6, 1, 8, 7, 6, 9,
            ])
        // 189 distinct spellings: 156 + ych ynh yt + êc êng + 13 Tier B extras + 15 k variants.
        #expect(SyllableTables.rhymes.count == 189)
        #expect(SyllableTables.rhymes.filter { $0.coda == .k }.count == 15)
    }

    @Test func tierAPairsAndTonedSyllables() {
        let pairs = SyllableTables.standardPairs
        let toned = pairs.reduce(0) { $0 + $1.tones.count }
        print("[ENG-R350] Tier A onset-rhyme pairs: \(pairs.count) (spec 3,368 counts g+iu and gi+u separately)")
        print("[ENG-R350] Tier A toned syllables: \(toned) (spec 15,412)")
        #expect(pairs.count == 3_367)
        #expect(toned == 15_406)
        // Reconciliation with spec 3.15: add back the duplicate the reference model counts.
        #expect(pairs.count + Self.modelDuplicatePairs.count == 3_368)
        #expect(toned + Self.modelDuplicateTonedSyllables == 15_412)
        // Every pair is spelled differently (the inventory has no duplicates by construction).
        #expect(Set(pairs.map(\.spelling)).count == pairs.count)
    }

    @Test func tierBPairs() {
        let pairs = SyllableTables.extendedPairs
        let withoutDz = pairs.filter { $0.onset != .dz }
        let dz = pairs.filter { $0.onset == .dz }
        let d = pairs.filter { $0.onset == .d }
        print(
            "[ENG-R350] Tier B pairs incl. Tier A, without dz: \(withoutDz.count) (spec 6,209 incl. the giu duplicate)")
        print(
            "[ENG-R350] Tier B pairs incl. Tier A, with dz: \(pairs.count) (dz adds \(dz.count), the Tier B pairs of d)"
        )
        #expect(withoutDz.count == 6_208)
        #expect(withoutDz.count + Self.modelDuplicatePairs.count == 6_209)
        #expect(pairs.count == 6_387)
        // 3.3: `dz` follows the same constraints as `d`.
        #expect(dz.map(\.rhyme) == d.map(\.rhyme))
        #expect(dz.allSatisfy { $0.tier == .extended })
        #expect(Set(pairs.map(\.spelling)).count == pairs.count)
    }

    @Test func tierAPairsPerOnset() {
        let expected: [String: Int] = [
            "": 148, "b": 113, "c": 81, "ch": 149, "d": 149, "g": 124, "gh": 32, "gi": 99, "h": 151, "k": 33,
            "kh": 149, "l": 150, "m": 114, "n": 149, "ng": 117, "ngh": 32, "nh": 149, "p": 113, "ph": 113, "qu": 41,
            "r": 149, "s": 150, "t": 150, "th": 151, "tr": 149, "v": 114, "x": 149, "đ": 149,
        ]
        let actual = Dictionary(grouping: SyllableTables.standardPairs, by: \.onset.spelling).mapValues(\.count)
        #expect(actual == expected)
    }

    @Test func tierBPairsPerOnset() {
        let expected: [String: Int] = [
            "": 176, "b": 179, "bl": 179, "br": 179, "c": 94, "ch": 179, "d": 179, "dr": 179, "dz": 179, "g": 151,
            "gh": 35, "gi": 131, "gl": 179, "gr": 179, "h": 179, "k": 129, "kh": 179, "kl": 129, "kr": 129, "l": 179,
            "m": 179, "n": 179, "ng": 144, "ngh": 35, "nh": 179, "p": 179, "ph": 179, "pl": 179, "pr": 179, "qu": 43,
            "r": 179, "s": 179, "t": 179, "th": 179, "tr": 179, "v": 179, "x": 179, "z": 179, "đ": 179, "đr": 179,
        ]
        let actual = Dictionary(grouping: SyllableTables.extendedPairs, by: \.onset.spelling).mapValues(\.count)
        #expect(actual == expected)
    }

    @Test func tonesPerRhymeFollowTheCoda() {
        // ENG-R320, ENG-R321.
        for rhyme in SyllableTables.rhymes {
            let tones = Tone.allTones.filter { rhyme.accepts($0) }
            switch rhyme.coda {
            case .stop: #expect(tones == [.acute, .dot], "\(rhyme)")
            default: #expect(tones.count == 6, "\(rhyme)")
            }
        }
    }

    @Test func chAndNhCodasOnlyAfterTheListedVowels() {
        // ENG-R303: a property of the 3.7 table, checked here for reviewers.
        let allowed: Set<String> = ["a", "ê", "i", "oa", "uê", "uy"]
        for rhyme in RhymeInventory.standard where rhyme.hasSuffix("ch") || rhyme.hasSuffix("nh") {
            #expect(allowed.contains(String(rhyme.dropLast(2))), "\(rhyme)")
        }
    }
}
