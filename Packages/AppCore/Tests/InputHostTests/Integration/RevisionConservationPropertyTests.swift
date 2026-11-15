// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R357 with PLT-R312: the scripted-engine property suite of the pipeline with the real inject worker, extended
// with revision outputs (a commit that rewrites the previous token in the same edit, ENG-R828) and their undo
// (ENG-R829). Random typing with held keys, a lagging window server and the worker running in random slices; at the
// end the field must show exactly what the engine's outputs say: every character the engine deleted was re-inserted
// or replaced exactly once, and the revision and its boundary key arrived in order. `swift test` runs a reduced count;
// PLATFORM_PROPERTY_SEQUENCES raises it (names contain "Property" for the CI filter).

import AppModel
import Foundation
import Injection
import TestSupport
import Testing

@testable import InputHost

private enum RevisionRun {
    static let sequences = ProcessInfo.processInfo.environment["PLATFORM_PROPERTY_SEQUENCES"].flatMap { Int($0) } ?? 600
    static let length = 56
    /// Letters (with `q`, the scripted revision trigger, and `s`, the scripted tone), Space three times as often,
    /// comma, Backspace, Return and Escape twice (the restore key: it undoes a revision right after it).
    static let keys: [UInt16] = [
        0x00, 0x00, 0x01, 0x01, 0x0D, 0x07, 0x0C, 0x0C, 0x1F, 0x0E, 0x31, 0x31, 0x31, 0x2B, 0x33, 0x24, 0x35, 0x35,
    ]

    static func steps(seed: UInt64) -> [RandomEventGenerator.Step] {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var steps: [RandomEventGenerator.Step] = []
        for _ in 0..<length {
            let code = keys[next(keys.count)]
            steps.append(.key(PipelineFixtures.keyEvent(.keyDown, code)))
            if next(3) == 0 { steps.append(.workerRuns(maxJobs: 1 + next(3))) }
            if next(3) == 0 { steps.append(.tapDrains(maxEvents: 1 + next(6))) }
            steps.append(.key(PipelineFixtures.keyEvent(.keyUp, code)))
            if next(4) == 0 { steps.append(.workerRuns(maxJobs: 1 + next(4))) }
        }
        return steps
    }
}

@Suite("Revision conservation Property suite (PLT-R357)")
struct RevisionConservationPropertyTests {
    /// With the read-back off (`verifyReentry: never`) every revision is applied as computed, so the field must show
    /// exactly what the engine's outputs say.
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func everyDeletedCharacterIsReinsertedOrReplacedExactlyOnceProperty(server: SimulatedWindowServer.Mode) {
        var failures: [String] = []
        var revisions = 0
        var undos = 0
        for index in 0..<RevisionRun.sequences {
            let seed = UInt64(0x5E57) &+ UInt64(index) &* 7_919 &+ (server == .immediate ? 0 : 1)
            let log = EngineEventLog(keepsEntries: true)
            let harness = CombinedHarness(
                factory: ScriptedEngineFactory(log: log), server: server, engineLog: log, verifyReentry: .never
            ) {
                PipelineFixtures.settings(generation: $0, restore: .key(KeyCode(rawValue: 0x35)))
            }
            harness.run(RevisionRun.steps(seed: seed))
            let model = ScriptedFieldModel(entries: log.entries)
            revisions += model.revisions
            undos += model.undos
            let violations = harness.violations
            guard harness.field.text != model.text || !violations.isEmpty else { continue }
            if failures.count < 3 {
                failures.append(
                    "seed \(seed): field \(harness.field.text.debugDescription) model \(model.text.debugDescription) "
                        + violations.prefix(3).map(\.description).joined(separator: "; "))
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(revisions > 50, "the suite exercised revisions (\(revisions))")
        #expect(undos > 5, "the suite exercised the undo of a revision (\(undos))")
    }

    /// With the read-back on (`whenReadable`), a revision whose read-back sees other text falls back to the current
    /// token and resets the engine: no key is lost, doubled or reordered either way (PLT-R311, PLT-R312).
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func revisionsWithTheReadBackConserveEveryKeyProperty(server: SimulatedWindowServer.Mode) {
        var failures: [String] = []
        for index in 0..<RevisionRun.sequences {
            let seed = UInt64(0xB0B) &+ UInt64(index) &* 7_919 &+ (server == .immediate ? 0 : 1)
            let log = EngineEventLog(keepsEntries: false)
            let harness = CombinedHarness(factory: ScriptedEngineFactory(log: log), server: server, engineLog: log) {
                PipelineFixtures.settings(generation: $0, restore: .key(KeyCode(rawValue: 0x35)))
            }
            harness.run(RevisionRun.steps(seed: seed))
            let violations = harness.violations
            if !violations.isEmpty, failures.count < 3 {
                failures.append("seed \(seed): " + violations.prefix(3).map(\.description).joined(separator: "; "))
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
