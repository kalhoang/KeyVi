// SPDX-License-Identifier: MPL-2.0
//
// ENG-T54 with the bundled data (spec/01-engine.md 11A.5; plan of 19/11/2026, Task 22 Step 1): the on-half of the
// fuzz campaign (`FuzzCombination.all`, the typo correction on, auto restore on, both methods, the general and code
// contexts) runs against `Resources.bundled` with each combination's random never-correct list, so that every
// invariant of ENG-T54 is checked against the real keyings, shapes and guard list. The fixture half is
// `FuzzTests.randomStreams` in the engine tests, which cannot load the bundled data (VietnameseEngineTests does not
// depend on VietnameseEngineData).

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T54: fuzz with the typo correction on and the bundled data")
struct TypoCorrectionFuzzTests {
    /// The on-half combinations with auto restore on.
    static let combinations = FuzzCombination.all.filter {
        $0.configuration.typoCorrection && $0.configuration.autoRestore
    }

    /// The per-PR size (QA-R8): `ENGINE_FUZZ_EVENTS` (default 1,000,000) spread over the combinations.
    static let totalEvents = max(
        combinations.count,
        ProcessInfo.processInfo.environment["ENGINE_FUZZ_EVENTS"].flatMap {
            Int($0.replacingOccurrences(of: "_", with: ""))
        } ?? FuzzCampaign.defaultEventCount)

    static let macros = Result { try RandomMacroTable.table() }

    @Test("ENG-T54: random streams with the bundled data", arguments: Array(combinations.indices))
    func randomStreamsWithTheBundledData(_ index: Int) throws {
        let combination = Self.combinations[index]
        var resources = try RealData.resources()
        resources.userKeepRaw = WordSet(["tets"])
        resources.userKeepVietnamese = WordSet(["test"])
        resources.userNeverCorrect = WordSet(combination.neverCorrect)
        let events = (Self.totalEvents + Self.combinations.count - 1) / Self.combinations.count
        let seed = 0x11A5_4000 &+ UInt64(index)
        var options = InvariantChecker.Options()
        options.nfcCheck = { $0.precomposedStringWithCanonicalMapping == $0 }
        let statistics: FuzzStatistics
        do {
            statistics = try FuzzCampaign.run(
                combination, seed: seed, events: events, macros: try Self.macros.get(), options: options,
                resources: resources)
        } catch let violation as FuzzViolation {
            Issue.record("\(combination) seed \(seed): \(violation)")
            return
        }
        #expect(statistics.events == events)
        #expect(statistics.commits > 0 && statistics.restoreChecks > 0 && statistics.replayChecks > 0)
        if combination.configuration.appContext == .general {
            #expect(statistics.correctedCommits > 0 && statistics.correctionUndos > 0, "\(combination)")
        } else {
            #expect(statistics.correctedCommits == 0 && statistics.correctionUndos == 0, "\(combination)")
        }
    }

    @Test("The bundled-data half covers both methods and both contexts, with never-correct lists")
    func theCombinationsCoverTheSwitchOnHalf() {
        #expect(Self.combinations.count == 40)
        #expect(Set(Self.combinations.map { $0.configuration.appContext == .code }).count == 2)
        #expect(Self.combinations.contains { $0.configuration.inputMethod == .vni })
        #expect(Self.combinations.contains { !$0.neverCorrect.isEmpty })
    }
}
