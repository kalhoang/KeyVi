// SPDX-License-Identifier: MPL-2.0
//
// The data decisions of the product owner (13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md, Q26, Q27 and
// Q29) with the bundled data: Telex `IX` types `Ĩ` while `XIX` stays; VNI `co2` types `cò` in every context and CO2
// needs the escape; `chơn` is attested and Telex `chown` keeps it outside the code context and in Vietnamese text (as a
// command in a terminal it keeps its keys since 18/11/2026, REG-38); the paper sizes keep their readings.

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

    @Test("Q26: Telex IX types Ĩ (ầm ĩ wins) and the Roman numeral XIX stays as typed")
    func romanNumeralNineIsVietnamese() throws {
        let resources = try RealData.resources()
        #expect(!resources.techAlways.contains("ix"))
        #expect(resources.ambiguity["ix"] == nil)
        #expect(resources.attestedSyllables.contains("ĩ"))
        #expect(resources.techAlways.contains("xix"))
        for seed in Self.telexSeeds {
            #expect(try Self.committed("IX ", after: seed, EngineConfiguration()) == "Ĩ ", "\(seed)")
            #expect(try Self.committed("aamf ix ", after: seed, EngineConfiguration()) == "ầm ĩ ", "\(seed)")
            #expect(try Self.committed("XIX ", after: seed, EngineConfiguration()) == "XIX ", "\(seed)")
        }
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

    @Test("Q29: chơn is attested, and Telex chown keeps it (rule L7) except as a command in the code context")
    func chonIsAttested() throws {
        #expect(try RealData.resources().attestedSyllables.contains("chơn"))
        for seed in Self.telexSeeds {
            #expect(try Self.committed("chown ", after: seed, EngineConfiguration()) == "chơn ", "\(seed)")
        }
        // The code context: since the product owner's decision of 18/11/2026 (REG-38) rule L9 is evaluated right after
        // L5 for `chown`, a code-only word whose keys are not English, so it keeps its keys outside Vietnamese text and
        // its Vietnamese display inside it (docs/decisions/0005-pa-decisions-2026-11-13.md, "Decisions of 18/11/2026").
        #expect(try Self.committed("chown ", after: "", Self.code) == "chown ")
        #expect(try Self.committed("chown ", after: "sudo ", Self.code) == "chown ")
        #expect(try Self.committed("chown ", after: "vieejt ", Self.code) == "chơn ")
        #expect(try Self.committed("chown ", after: "tay ", Self.code) == "chơn ")
    }
}
