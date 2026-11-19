// SPDX-License-Identifier: GPL-3.0-or-later
//
// 02-platform.md 13.1 property suites over the W1-F1 harness and reference consumer: conservation (PLT-R312),
// hold-while-busy ordering including keys queued at the server before a post (PLT-R311, ADR 0311), keyUp
// pairing (PLT-R313), marker never on physical events (PLT-R321), fail-open in the same callback (PLT-R730),
// composition reset on every host transition (PLT-R210) and counted losses after posting broke (ADR 0308).
//
// `swift test` runs a reduced count; CI and the nightly set PLATFORM_PROPERTY_SEQUENCES=100000 (per window
// server mode). PLATFORM_PROPERTY_SEED changes the base seed. Suite and test names contain "Property" so the
// CI filter `Property|Fuzz|Invariant` selects them.

import Foundation
import Injection
import TestSupport
import Testing

@testable import InputHost

private enum PropertyRun {
    static let sequences = environment("PLATFORM_PROPERTY_SEQUENCES") ?? 2_000
    static let baseSeed = UInt64(environment("PLATFORM_PROPERTY_SEED") ?? 0x5EED)
    static let length = 64

    static func environment(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0) }
    }

    struct Failure: CustomStringConvertible {
        var seed: UInt64
        var violations: [ConservationLedger.Violation]
        var description: String { "seed \(seed): \(violations.prefix(5).map(\.description).joined(separator: "; "))" }
    }

    struct Summary {
        var failures: [Failure] = []
        var runsWithViolations = 0
        var runsWithLosses = 0
        var lost: UInt64 = 0
        var statistics = HarnessStatistics()
        var flushes: UInt64 = 0
    }

    /// Runs `count` seeded sequences; keeps the first few failures with their seeds for reproduction.
    static func run(
        count: Int = sequences, server: SimulatedWindowServer.Mode, policy: InFlightPolicy = .untilEcho,
        postingBreaks: Bool = false, salt: UInt64
    ) -> Summary {
        var summary = Summary()
        for index in 0..<count {
            let seed = baseSeed &+ salt &* 1_000_003 &+ UInt64(index)
            var generator = RandomEventGenerator(seed: seed, includePostingBreaks: postingBreaks)
            let harness = PipelineHarness(
                field: SimulatedTextField(), layout: PipelineFixtures.qwertyTable(), clock: ManualClock(),
                server: server, policy: policy)
            harness.run(generator.sequence(length: length))
            let violations = harness.ledger.violations()
            let lost = harness.metrics.lostWhilePostingBroken.value
            summary.statistics.add(harness.statistics)
            summary.flushes += harness.metrics.flushes.value
            summary.lost += lost
            if lost > 0 { summary.runsWithLosses += 1 }
            if !violations.isEmpty {
                summary.runsWithViolations += 1
                if summary.failures.count < 3 { summary.failures.append(Failure(seed: seed, violations: violations)) }
            }
        }
        return summary
    }
}

@Suite("PipelinePropertyTests") struct PipelinePropertyTests {
    /// The scripted typo correction (a token ending in `nn` is corrected at its commit, and the restore key right after
    /// undoes it, ENG-R1115, ENG-R1117) is in the random streams, so the properties below hold with corrections and
    /// their undos in them: some sequences type `nn` right before a committing key.
    @Test func theScriptedCorrectionIsInTheRandomStreamsProperty() {
        let committing: Set<UInt16> = [Key.space, Key.comma, Key.returnKey, Key.tab]
        var found = 0
        for index in 0..<200 {
            var generator = RandomEventGenerator(seed: PropertyRun.baseSeed &+ 1_000_003 &+ UInt64(index))
            var lastTwo: [UInt16] = []
            for step in generator.sequence(length: PropertyRun.length) {
                guard case .key(let event) = step, event.kind == .keyDown, event.flags & 0x0018_0000 == 0 else {
                    continue
                }
                let code = event.keyCode.rawValue
                if committing.contains(code), lastTwo == [Key.n, Key.n] { found += 1 }
                lastTwo = Array((lastTwo + [code]).suffix(2))
            }
        }
        #expect(found > 0)
    }

    /// PLT-R311, PLT-R312, PLT-R313, PLT-R321, PLT-R730, PLT-R210 over random interleavings of keys, Command
    /// and Option chords, the restore binding, mouse downs, scrolls, focus, settings and input-source changes,
    /// tap-disabled events, secure-input toggles and permission changes.
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func conservationOrderingAndPairingProperty(server: SimulatedWindowServer.Mode) {
        let summary = PropertyRun.run(server: server, salt: server == .immediate ? 1 : 2)
        #expect(summary.failures.isEmpty, "\(summary.runsWithViolations) failing sequences: \(summary.failures)")
        expectNotVacuous(summary)
    }

    /// Every path the invariants talk about was taken at least once.
    private func expectNotVacuous(_ summary: PropertyRun.Summary) {
        let stats = summary.statistics
        // `consumedAsHotkey` comes from the restore binding (Escape in every other settings generation).
        for outcome in [EventOutcome.passed, .held, .consumedForEdit, .consumedPairedKeyUp, .consumedAsHotkey] {
            #expect(stats.outcomes[outcome, default: 0] > 0, "no \(outcome) outcome")
        }
        #expect(stats.editsDelivered > 0 && stats.replaysDelivered > 0 && stats.echoesSeen > 0)
        #expect(stats.discardedEdits > 0, "no edit was discarded for a focus change (PLT-R316)")
        #expect(stats.editsNearFocusChange > 0, "no word began right after a focus change or click (PLT-R408)")
        #expect(summary.flushes > 0, "no liveness flush (PLT-R314)")
        #expect(stats.toggles > 0 && stats.secureResumes > 0 && stats.failOpenEvents > 0)
    }

    /// ADR 0308 amendment, ADR 0311: with the poster dropping silently mid-sequence nothing is lost before the
    /// switch, and every loss after it is counted (`lostWhilePostingBroken` equals the ledger).
    @Test(arguments: [SimulatedWindowServer.Mode.immediate, .lagging])
    func postingBrokenMidSequenceProperty(server: SimulatedWindowServer.Mode) {
        let summary = PropertyRun.run(server: server, postingBreaks: true, salt: server == .immediate ? 3 : 4)
        #expect(summary.failures.isEmpty, "\(summary.runsWithViolations) failing sequences: \(summary.failures)")
        #expect(summary.runsWithLosses > 0, "the suite never exercised a loss after posting broke")
        // The losses must come with the echo-loss detection (three misses, PLT-R323) failing open in the same
        // callback, not only with the reference consumer counting drops.
        #expect(summary.statistics.postingBrokenNotices > 0, "echo-loss detection never marked posting broken")
    }

    /// Self-check of ADR 0311: with "in flight until posted" a key queued at the WindowServer before the post
    /// overtakes the edit, and the lagging model must see it.
    @Test func untilPostedIsCaughtByTheLaggingModelProperty() {
        let summary = PropertyRun.run(
            count: max(200, PropertyRun.sequences / 10), server: .lagging, policy: .untilPosted, salt: 5)
        let ordering = summary.failures.flatMap(\.violations).filter { $0.reason.hasPrefix("ordering") }
        #expect(summary.runsWithViolations > 0)
        #expect(!ordering.isEmpty, "untilPosted produced no ordering violation: the model cannot see the bug")
    }
}

@Suite struct PipelineHarnessScenarioTests {
    private typealias Step = RandomEventGenerator.Step

    private func key(_ kind: RawKeyEvent.Kind, _ code: UInt16) -> Step {
        .key(PipelineFixtures.keyEvent(kind, code))
    }

    /// The key typed before the worker posted sits in front of the edit at the server; it is held and lands
    /// after the edit (ADR 0311).
    private var keyQueuedBeforeThePost: [Step] {
        [
            key(.keyDown, Key.a), key(.keyUp, Key.a), .tapDrains(maxEvents: Int.max),
            key(.keyDown, Key.a), .tapDrains(maxEvents: Int.max),  // edit "â" pushed
            key(.keyDown, Key.d),  // reaches the server before the worker posts
            .workerRuns(maxJobs: 4), .tapDrains(maxEvents: Int.max), .workerRuns(maxJobs: 4),
        ]
    }

    @Test func heldKeyLandsAfterTheEditWhenInFlightLastsUntilTheEcho() {
        let harness = PipelineHarness(
            field: SimulatedTextField(), layout: PipelineFixtures.qwertyTable(), clock: ManualClock(), server: .lagging)
        harness.run(keyQueuedBeforeThePost)
        #expect(harness.field.text == "âd")
        #expect(harness.ledger.violations().isEmpty)
    }

    @Test func untilPostedGarblesTheSameInput() {
        let harness = PipelineHarness(
            field: SimulatedTextField(), layout: PipelineFixtures.qwertyTable(), clock: ManualClock(), server: .lagging,
            policy: .untilPosted)
        harness.run(keyQueuedBeforeThePost)
        #expect(harness.field.text != "âd")
        #expect(harness.ledger.violations().contains { $0.reason.hasPrefix("ordering") })
    }

    @Test func immediateTypingProducesTheComposedText() {
        let harness = PipelineHarness(
            field: SimulatedTextField(), layout: PipelineFixtures.qwertyTable(), clock: ManualClock())
        var steps: [Step] = []
        for code in [Key.a, Key.a, Key.s, Key.space, Key.u, Key.w] {
            steps += [key(.keyDown, code), .workerRuns(maxJobs: 8), key(.keyUp, code), .workerRuns(maxJobs: 8)]
        }
        harness.run(steps)
        #expect(harness.field.text == "ấ ư")
        #expect(harness.ledger.violations().isEmpty)
        #expect(harness.metrics.lostWhilePostingBroken.value == 0)
        #expect(harness.engineLog.resetViolations == 0)
    }

    /// PLT-R730 end to end: posting breaks silently, the tap detects it after three misses and fails open;
    /// losses are counted and recovery composes again.
    @Test func postingBreaksAndRecovers() {
        let harness = PipelineHarness(
            field: SimulatedTextField(), layout: PipelineFixtures.qwertyTable(), clock: ManualClock())
        var steps: [Step] = [.postingWorks(false)]
        for code in [Key.a, Key.a, Key.s, Key.w, Key.d] {
            steps += [key(.keyDown, code), .workerRuns(maxJobs: 8), key(.keyUp, code), .workerRuns(maxJobs: 8)]
            steps.append(.advanceMicroseconds(250_000))
        }
        steps += [key(.keyDown, Key.e), key(.keyUp, Key.e), .postingWorks(true)]
        steps += [key(.keyDown, Key.a), .workerRuns(maxJobs: 8), key(.keyUp, Key.a), .workerRuns(maxJobs: 8)]
        harness.run(steps)
        #expect(harness.ledger.violations().isEmpty)
        #expect(harness.metrics.lostWhilePostingBroken.value > 0)
        #expect(harness.mainNotices.contains { if case .postingBroken = $0 { true } else { false } })
    }
}
