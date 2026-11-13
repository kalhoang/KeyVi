// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W2-A combined property suite (02-platform.md 13.1, QA-R1 layer 4): the pipeline with the REAL inject worker
// in step mode, with the scripted engine and with the real engine, in both window-server modes. Properties:
// conservation (PLT-R312), ordering (PLT-R311), liveness (PLT-R314: every run settles with nothing in flight),
// generation discard (PLT-R316: no edit reaches a field after its focus changed), keyUp pairing (PLT-R313),
// echoes passed unchanged (PLT-R321, PLT-R323), fail-open passes everything (PLT-R730) and resets before every
// feed after a host transition (PLT-R210, scripted engine).
//
// `swift test` runs a reduced count; CI and the nightly set PLATFORM_PROPERTY_SEQUENCES=100000 (per engine and
// window-server mode), as for the W1-F1 suite. PLATFORM_PROPERTY_SEED changes the base seed. Names contain
// "Property" so the CI filter `Property|Fuzz|Invariant` selects them. Workstream W2-A.

import AppModel
import Foundation
import Injection
import SettingsStore
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private enum CombinedRun {
    static let sequences = environment("PLATFORM_PROPERTY_SEQUENCES") ?? 1_000
    static let baseSeed = UInt64(environment("PLATFORM_PROPERTY_SEED") ?? 0xC0B1)
    static let length = 64

    static func environment(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0) }
    }

    struct Summary {
        var failures: [String] = []
        var failing = 0
        var statistics = CombinedStatistics()
    }

    static func run<Factory: CompositionEngineFactory>(
        server: SimulatedWindowServer.Mode, postingBreaks: Bool, salt: UInt64,
        makeHarness: (SimulatedWindowServer.Mode) -> CombinedHarness<Factory>
    ) -> Summary {
        var summary = Summary()
        for index in 0..<sequences {
            let seed = baseSeed &+ salt &* 1_000_003 &+ UInt64(index)
            var generator = RandomEventGenerator(seed: seed, includePostingBreaks: postingBreaks)
            let harness = makeHarness(server)
            harness.run(generator.sequence(length: length))
            summary.statistics.add(harness.statistics)
            let violations = harness.violations
            guard !violations.isEmpty else { continue }
            summary.failing += 1
            if summary.failures.count < 3 {
                summary.failures.append(
                    "seed \(seed): " + violations.prefix(4).map(\.description).joined(separator: "; "))
            }
        }
        return summary
    }

    /// Real engine settings: two prebuilt catalogs, the revision changes every third generation (PRD-R27).
    static let realCatalogs: [EngineCatalog] = [0, 1].map { revision in
        EngineBridge.catalog(settings: DefaultSettings.v1, resources: .empty, revision: UInt64(revision))
    }

    static func realSettings(generation: UInt64) -> TapSettingsSnapshot {
        let revision = Int(generation / 3 % 2)
        return TapSettingsSnapshot(
            generation: generation, engines: realCatalogs[revision], toggleHotkey: .defaultToggle,
            restoreHotkey: generation % 2 == 1 ? .key(KeyCode(rawValue: 0x35)) : nil, macrosInEnglishMode: false,
            rememberPerApp: true)
    }

    static func scripted(_ server: SimulatedWindowServer.Mode) -> CombinedHarness<ScriptedEngineFactory> {
        scripted(server, policy: .untilEcho)
    }

    static func scripted(_ server: SimulatedWindowServer.Mode, policy: InFlightPolicy)
        -> CombinedHarness<ScriptedEngineFactory>
    {
        let log = EngineEventLog(keepsEntries: false)
        return CombinedHarness(
            factory: ScriptedEngineFactory(log: log), server: server, engineLog: log, policy: policy
        ) { generation in
            PipelineFixtures.settings(
                generation: generation, restore: generation % 2 == 1 ? .key(KeyCode(rawValue: 0x35)) : nil,
                engineRevision: generation / 3)
        }
    }

    static func real(_ server: SimulatedWindowServer.Mode) -> CombinedHarness<VietnameseCompositionEngineFactory> {
        CombinedHarness(
            factory: VietnameseCompositionEngineFactory(), server: server, engineLog: nil, settingsFor: realSettings)
    }
}

@Suite("Combined pipeline and real worker Property suite (13.1)")
struct CombinedPropertyTests {
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func scriptedEngineRealWorkerProperty(server: SimulatedWindowServer.Mode) {
        let summary = CombinedRun.run(
            server: server, postingBreaks: false, salt: server == .immediate ? 11 : 12,
            makeHarness: CombinedRun.scripted)
        #expect(summary.failures.isEmpty, "\(summary.failing) failing sequences: \(summary.failures)")
        expectNotVacuous(summary.statistics)
    }

    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func realEngineRealWorkerProperty(server: SimulatedWindowServer.Mode) {
        let summary = CombinedRun.run(
            server: server, postingBreaks: false, salt: server == .immediate ? 21 : 22, makeHarness: CombinedRun.real)
        #expect(summary.failures.isEmpty, "\(summary.failing) failing sequences: \(summary.failures)")
        expectNotVacuous(summary.statistics)
    }

    /// Posting breaks silently mid-sequence (ADR 0308, ADR 0311): nothing is delivered twice or out of order
    /// before the break, pairs stay paired, and the harness still settles.
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func postingBreaksWithTheRealWorkerProperty(server: SimulatedWindowServer.Mode) {
        let summary = CombinedRun.run(
            server: server, postingBreaks: true, salt: server == .immediate ? 31 : 32, makeHarness: CombinedRun.scripted
        )
        #expect(summary.failures.isEmpty, "\(summary.failing) failing sequences: \(summary.failures)")
        #expect(summary.statistics.postingBrokenNotices > 0, "the echo-loss detection fired")
    }

    /// Self-check: the harness is not blind. With "in flight until posted" (ADR 0311's rejected reading) a key
    /// queued at the WindowServer before the post overtakes the edit, and the lagging model must report it.
    @Test func untilPostedIsCaughtWithTheRealWorkerProperty() {
        let summary = CombinedRun.run(server: .lagging, postingBreaks: false, salt: 41) {
            CombinedRun.scripted($0, policy: .untilPosted)
        }
        #expect(summary.failing > 0, "ordering violations must be visible to the combined harness")
    }
}

private func expectNotVacuous(_ statistics: CombinedStatistics) {
    #expect(statistics.editsDelivered > 0, "edits reached the field")
    #expect(statistics.replaysDelivered > 0, "held keys were replayed")
    #expect(statistics.held > 0, "keys were held while jobs were in flight")
    #expect(statistics.flushes > 0, "the liveness ceiling fired")
    #expect(statistics.generationDiscards > 0, "stale edits were discarded")
}
