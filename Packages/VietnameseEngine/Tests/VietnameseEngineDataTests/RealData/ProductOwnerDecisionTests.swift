// SPDX-License-Identifier: MPL-2.0
//
// The data decisions of the product owner (13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, Q27 and
// Q29) with the bundled data: VNI `co2` types `cò` in every context and CO2 needs the escape; `chơn` is
// attested and Telex `chown` keeps it outside the code context; the paper sizes keep their readings.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("Data decisions of the product owner with the bundled data")
struct ProductOwnerDecisionTests {
    static let vni = EngineConfiguration(inputMethod: .vni)
    static let code = EngineConfiguration(appContext: .code)
    /// No previous token, a Vietnamese seed (`việt`) and an English seed (`and`, ENG-R823).
    static let telexSeeds = ["", "vieejt ", "and "]
    static let vniSeeds = ["", "vie65t ", "and "]

    /// The text that `keys` commits after `seed`, with the seed's own output removed.
    static func committed(_ keys: String, after seed: String, _ configuration: EngineConfiguration) throws -> String {
        var driver = EngineDriver(configuration: configuration, resources: try RealData.resources())
        try driver.type(seed)
        let before = driver.field.string
        try driver.type(keys)
        return String(driver.field.string.dropFirst(before.count))
    }

    @Test("Q27: VNI co2 types cò in every context, and the escape keeps CO2")
    func co2IsVietnamese() throws {
        let resources = try RealData.resources()
        #expect(!resources.techAlways.contains("co2"))
        #expect(resources.ambiguity["co2"] == nil)
        #expect(resources.attestedSyllables.contains("cò"))
        for seed in Self.vniSeeds {
            #expect(try Self.committed("co2 ", after: seed, Self.vni) == "cò ", "after \(seed.debugDescription)")
            #expect(try Self.committed("co22 ", after: seed, Self.vni) == "co2 ", "after \(seed.debugDescription)")
        }
    }

    @Test("Q27: the VNI paper sizes keep their readings")
    func paperSizes() throws {
        #expect(try Self.committed("a3 ", after: "vie65t ", Self.vni) == "ả ")
        #expect(try Self.committed("a5 ", after: "vie65t ", Self.vni) == "ạ ")
        #expect(try Self.committed("a4 ", after: "vie65t ", Self.vni) == "a4 ")
    }

    @Test("Q29: chơn is attested, and Telex chown keeps it (rule L7)")
    func chonIsAttested() throws {
        #expect(try RealData.resources().attestedSyllables.contains("chơn"))
        for seed in Self.telexSeeds {
            #expect(try Self.committed("chown ", after: seed, EngineConfiguration()) == "chơn ", "\(seed)")
        }
        // The code context gives the same: `chown` is a code-only word, not English by 8.1, so L7 keeps the
        // display before L9 is reached. Whether L9 should restore such words is an open point for the product
        // owner (docs/decisions/0005-pa-decisions-2026-11-13.md, "Found while applying the decisions").
        #expect(try Self.committed("chown ", after: "", Self.code) == "chơn ")
    }
}
