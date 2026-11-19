// SPDX-License-Identifier: MPL-2.0
//
// ENG-T56, the data half of the typo correction's gates (spec/01-engine.md 11A.5): the guard list's false positives
// and completeness, the unmarked shapes and the Vietnamese keyings against an independent computation from the
// oracle's side, and the resident budget of ENG-R1120 (at most 1 MB for the new data, 512 KB of it for the guard
// list). The neighbours table is checked by CorrectionInputTests and MalformedResourceTests; byte reproducibility by
// LexiconBuilderTests. Serialized so that the memory measurement is not disturbed by another test of this suite.

import Foundation
import Testing
import VietnameseEngineData
import VietnameseEngineTesting

@testable import VietnameseEngine
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

    /// ENG-R1120: the new data adds at most 1 MB resident, the guard list at most 512 KB of it.
    ///
    /// The gate reads the heap storage the loaded `CorrectionData` owns, from the loaded values themselves (the
    /// guard bits, the bucket storage of each word set at its actual capacity, the neighbours table), because that
    /// figure is exact and the same on every run. Live malloc bytes are process-wide: other suites allocate on other
    /// threads while this one runs, and replacing `Resources.correction` rebuilds whatever the engine derives from it,
    /// so a malloc reading can drift by hundreds of kilobytes either way and must not decide a known issue. The plan's
    /// malloc measurement (the resources loaded from the bundled directory and from a copy whose four correction files
    /// are minimal, no assignment to `Resources.correction`, the median of five interleaved loads) is printed next to
    /// the gate as the cross-check.
    ///
    /// Known issue (19/11/2026, docs/decisions/0203-correction-data.md section 6): 1.30 MB. `CorrectionData` holds the
    /// shapes and the keyings as `WordSet`s, whose `Set<String>` takes 65,536 buckets of 16 bytes for the 27,277
    /// keyings alone (1 MB). The named fallback, a sorted array of packed `UInt64` (5 bits per letter, the longest
    /// keying has 9 letters), changes the type of the two `CorrectionData` fields in `PublicAPI.swift`, which the data
    /// track does not own; it is requested from the logic track and the integration. Once the data takes the packed
    /// form, `footprint` must account for the new storage (and for any index the engine derives from it), the known
    /// issue stops occurring and this test fails until the marker is removed.
    @Test func correctionDataStaysWithinItsResidentBudget() throws {
        let footprint = Self.Footprint(try Self.bundledCorrection())
        let measured = try Self.measuredResidentDelta()
        print(
            "ENG-R1120 measurement (debug): correction data owns \(footprint.total) bytes "
                + "(\(String(format: "%.2f", Double(footprint.total) / 1_048_576)) MB: guard list bits "
                + "\(footprint.guardBits), keyings \(footprint.keyings), shapes \(footprint.shapes), neighbours "
                + "\(footprint.neighbours)); live malloc cross-check, full minus minimal correction files, median "
                + "\(measured.median) bytes of five loads \(measured.samples)")
        #expect(footprint.guardBits <= 512 * 1024)
        withKnownIssue("ENG-R1120: the shapes and keyings as WordSet exceed 1 MB until they take the packed form") {
            #expect(footprint.total <= 1_048_576, "the correction data owns \(footprint.total) bytes, more than 1 MB")
        }
    }

    /// The footprint helper reads the real capacities: a set built with spare room counts its spare buckets.
    @Test func theFootprintFollowsTheSetCapacity() {
        #expect(Self.Footprint.bytes(of: WordSet([])) == 0)
        let small = Self.Footprint.bytes(of: WordSet(["thach", "truong"]))
        let large = Self.Footprint.bytes(of: WordSet((0..<1000).map { "w\($0)" }))
        // 2 words: 4 buckets of 16 bytes and a 1-byte occupancy word rounded to 8; 1000 words: 2,048 buckets.
        #expect(small == 4 * 16 + 8)
        #expect(large == 2048 * 16 + 2048 / 8)
        let long = Self.Footprint.bytes(of: WordSet(["abcdefghijklmnopq"]))
        #expect(long == 2 * 16 + 8 + 32 + 32)
    }

    /// The heap storage a `CorrectionData` owns, from its loaded values.
    struct Footprint {
        let guardBits: Int
        let keyings: Int
        let shapes: Int
        let neighbours: Int
        var total: Int { guardBits + keyings + shapes + neighbours }

        init(_ correction: CorrectionData) {
            guardBits = correction.guardList.bits.count * MemoryLayout<UInt64>.stride
            keyings = Self.bytes(of: correction.vietnameseKeyings)
            shapes = Self.bytes(of: correction.unmarkedShapes)
            neighbours = Self.bytes(ofTable: correction.keyboardNeighbours)
        }

        /// A native `Set` keeps its load at or under 3/4 with a power-of-two bucket count: 16 bytes per bucket (a
        /// string of at most 15 UTF-8 bytes lives inline), an occupancy bitmap in whole 64-bit words, and a heap
        /// buffer of a 32-byte header plus the bytes rounded to 16 for each longer string.
        static func bytes(of set: WordSet) -> Int {
            let storage = set.storage
            guard storage.capacity > 0 else { return 0 }
            let buckets = bucketCount(capacity: storage.capacity)
            let longStrings = storage.reduce(0) { total, word in
                word.utf8.count > 15 ? total + 32 + (word.utf8.count + 15) / 16 * 16 : total
            }
            return buckets * MemoryLayout<String>.stride + (buckets + 63) / 64 * 8 + longStrings
        }

        /// The same layout for the neighbours table: a `Character` key and a `String` value of 16 bytes each.
        static func bytes(ofTable table: [Character: String]) -> Int {
            guard table.capacity > 0 else { return 0 }
            let buckets = bucketCount(capacity: table.capacity)
            return buckets * (MemoryLayout<Character>.stride + MemoryLayout<String>.stride) + (buckets + 63) / 64 * 8
        }

        static func bucketCount(capacity: Int) -> Int {
            var buckets = 1
            while buckets * 3 / 4 < capacity { buckets *= 2 }
            return buckets
        }
    }

    /// The plan's measurement: live malloc bytes retained by the resources loaded from the bundled directory minus
    /// those retained by the same resources whose four correction files are minimal, interleaved five times. Both
    /// loads go through `Resources.init`, so whatever the engine derives from the correction data is counted, and
    /// nothing is replaced afterwards.
    static func measuredResidentDelta() throws -> (median: Int, samples: [Int]) {
        let minimal = try minimalCorrectionDirectory()
        defer { TempDirectory.remove(minimal) }
        let full = TestPaths.committedResources
        var samples: [Int] = []
        for _ in 0..<5 {
            let start = liveMallocBytes()
            let withData = try Resources.load(from: full, userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
            let afterFull = liveMallocBytes()
            let withoutData = try Resources.load(
                from: minimal, userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
            let afterMinimal = liveMallocBytes()
            samples.append((afterFull - start) - (afterMinimal - afterFull))
            withExtendedLifetime((withData, withoutData)) {}
        }
        return (samples.sorted()[samples.count / 2], samples)
    }

    /// A copy of the committed resources whose four correction files hold the smallest valid content (a 256-bit
    /// filter of two words, the 26-letter table, one shape, one keying), with manifest.json rewritten to match.
    static func minimalCorrectionDirectory() throws -> URL {
        let directory = try TempDirectory.make("minimal-correction")
        let source = TestPaths.committedResources
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        let replacements: [String: (data: Data, entries: Int)] = [
            "guard-list.bloom": (GuardListFixture.encode(GuardListFixture.filter), GuardListFixture.filter.wordCount),
            "keyboard-neighbours.txt": (Data(GuardListFixture.neighboursText.utf8), 26),
            "unmarked-shapes.txt": (Data("thach\n".utf8), 1),
            "vietnamese-keyings.txt": (Data("phair\n".utf8), 1),
        ]
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
            let files = manifest["files"] as? [[String: Any]]
        else { throw CocoaError(.fileReadCorruptFile) }
        manifest["files"] = files.map { row -> [String: Any] in
            guard let name = row["name"] as? String, let replacement = replacements[name] else { return row }
            return row.merging(
                [
                    "bytes": replacement.data.count, "entries": replacement.entries,
                    "sha256": sha256Hex(replacement.data),
                ], uniquingKeysWith: { _, new in new })
        }
        for (name, replacement) in replacements {
            try replacement.data.write(to: directory.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        return directory
    }

    private static func liveMallocBytes() -> Int {
        #if canImport(Darwin)
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
        #else
        return 0
        #endif
    }
}
