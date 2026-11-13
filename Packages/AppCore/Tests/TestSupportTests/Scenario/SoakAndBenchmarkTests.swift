// SPDX-License-Identifier: GPL-3.0-or-later
//
// QA-R16 soak plan and verdict, PLT-R821/PLT-R822 benchmark format (ADR 0502) and the committed platform
// baseline. Virtual time and fakes only.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct SoakPlanTests {
    private let native = makeScenario(id: "native")
    private let terminal = makeScenario(id: "terminal", readback: .terminalCapture)

    @Test func plansExactlyTheRequestedKeystrokes() {
        for total in [16, 17, 399, 400, 401, 415, 416, 1000, 12_345] {
            let plan = SoakPlan.make(keystrokes: total, targets: [native, terminal], seed: 1)
            #expect(plan.keystrokes == total, "\(total)")
            #expect(plan.chunks.allSatisfy { $0.keys.count >= SoakPlan.minimumKeystrokes })
        }
        #expect(SoakPlan.make(keystrokes: 1_000_000, targets: [native], seed: 1).chunks.count == 2500)
    }

    @Test func tooSmallOrNoTargetsGivesAnEmptyPlan() {
        #expect(SoakPlan.make(keystrokes: 15, targets: [native], seed: 1).chunks.isEmpty)
        #expect(SoakPlan.make(keystrokes: 100, targets: [], seed: 1).chunks.isEmpty)
    }

    @Test func framingDependsOnTheReadback() {
        let plan = SoakPlan.make(keystrokes: 64, targets: [native, terminal], seed: 5, chunkKeystrokes: 32)
        #expect(plan.chunks.map(\.target) == [0, 1])
        #expect(Array(plan.chunks[0].keys.prefix(2)) == ["command+a", "backspace"])
        #expect(plan.chunks[1].keys.last == "return")
        #expect(!plan.chunks[1].keys.contains("command+a"))
    }

    @Test func expectedTextFollowsTheCorpus() throws {
        let plan = SoakPlan.make(keystrokes: 400, targets: [terminal], seed: 9)
        let chunk = try #require(plan.chunks.first)
        // Rebuild the text from the keys: words are separated by "space", padding spaces at the end.
        let body = chunk.keys.dropLast()  // "return"
        var words: [String] = []
        var current = ""
        for key in body {
            if key == "space" {
                words.append(current)
                current = ""
            } else {
                current += key
            }
        }
        words.append(current)
        let table = Dictionary(uniqueKeysWithValues: SoakCorpus.words.map { ($0.keys, $0.text) })
        let rebuilt = words.map { $0.isEmpty ? "" : table[$0]! }.joined(separator: " ")
        #expect(rebuilt == chunk.expectedText)
        #expect(chunk.keys.allSatisfy { ScenarioKeys.stroke($0) != nil })
    }

    @Test func corpusIsUnambiguousTelex() {
        #expect(Set(SoakCorpus.words.map(\.keys)).count == SoakCorpus.words.count)
        for word in SoakCorpus.words {
            #expect(word.keys.allSatisfy { $0.isASCII && $0.isLowercase }, "\(word.keys)")
            #expect(word.text == word.text.precomposedStringWithCanonicalMapping)
        }
    }

    @Test func seededPlansRepeat() {
        let first = SoakPlan.make(keystrokes: 900, targets: [native], seed: 77)
        #expect(SoakPlan.make(keystrokes: 900, targets: [native], seed: 77) == first)
        #expect(SoakPlan.make(keystrokes: 900, targets: [native], seed: 78) != first)
    }
}

@Suite struct SoakRunnerTests {
    @Test func passingSoakMeasuresGrowthAndChecksModifiers() async {
        let clock = ManualClock()
        let target = makeScenario(id: "t")
        let plan = SoakPlan.make(keystrokes: 64, targets: [target], seed: 1, chunkKeystrokes: 16)
        // A readback that echoes each chunk's expectation makes every chunk pass.
        let runner = ScenarioRunner(
            driver: FakeDriver(), readback: EchoReadback(), setup: FakeSetup(), probe: nil, clock: clock)
        let monitor = ScriptedSoakMonitor(footprints: [30, 31, 32, 33], clock: clock, stepMicroseconds: 1_800_000_000)
        let summary = await SoakRunner(
            targets: [target], runner: runner, monitor: monitor, clock: clock, sampleEveryChunks: 1
        )
        .run(plan)
        #expect(summary.failures.isEmpty)
        #expect(summary.samples.count == 4)
        #expect(summary.growthMegabytesPerHour == 2)
        #expect(summary.passed)
    }

    @Test func growthAboveTheM2GateFails() async {
        let clock = ManualClock()
        let target = makeScenario(id: "t")
        let runner = ScenarioRunner(
            driver: FakeDriver(), readback: EchoReadback(), setup: FakeSetup(), probe: nil, clock: clock)
        let monitor = ScriptedSoakMonitor(footprints: [30, 40], clock: clock, stepMicroseconds: 3_600_000_000)
        let plan = SoakPlan.make(keystrokes: 32, targets: [target], seed: 1, chunkKeystrokes: 16)
        let summary = await SoakRunner(targets: [target], runner: runner, monitor: monitor, clock: clock).run(plan)
        #expect(summary.growthMegabytesPerHour == 10)
        #expect(!summary.passed)
    }

    @Test func heldModifierFailsTheSoak() async {
        let clock = ManualClock()
        let target = makeScenario(id: "t")
        let runner = ScenarioRunner(
            driver: FakeDriver(), readback: EchoReadback(), setup: FakeSetup(), probe: nil, clock: clock)
        let monitor = ScriptedSoakMonitor(footprints: [30], heldFlags: 0x0002_0102, clock: clock)
        let plan = SoakPlan.make(keystrokes: 16, targets: [target], seed: 1)
        let summary = await SoakRunner(targets: [target], runner: runner, monitor: monitor, clock: clock).run(plan)
        #expect(summary.stuckModifierFlags == 0x0002_0000)  // shift; the non-modifier bits are ignored
        #expect(summary.growthMegabytesPerHour == nil)  // one sample cannot show growth
        #expect(!summary.passed)
    }

    /// 13.6, QA-R16: setup runs once per target. Later chunks only bring the app to the front and refocus the
    /// field, so a 1,000,000-keystroke soak neither relaunches apps nor opens hundreds of terminal windows.
    @Test func setupRunsOncePerTargetAndLaterChunksOnlyReactivate() async {
        let clock = ManualClock()
        var editor = makeScenario(
            id: "editor",
            setup: [
                .init(action: .launch), .init(action: .wait, value: "1500"), .init(action: .focusField, value: "f"),
            ])
        editor.layout = InputSourceID(rawValue: "com.apple.keylayout.ABC")
        let terminal = makeScenario(id: "terminal", setup: [.init(action: .launch)], readback: .terminalCapture)
        let setup = FakeSetup()
        let runner = ScenarioRunner(
            driver: FakeDriver(), readback: EchoReadback(), setup: setup, probe: nil, clock: clock)
        let activated = Recorder<String>()
        let plan = SoakPlan.make(keystrokes: 16 * 6, targets: [editor, terminal], seed: 1, chunkKeystrokes: 16)
        let summary = await SoakRunner(
            targets: [editor, terminal], runner: runner, monitor: nil, clock: clock,
            activate: { activated.append($0.id) }
        )
        .run(plan)
        #expect(summary.chunks == 6 && summary.failures.isEmpty)
        #expect(
            setup.steps.all.map(\.action) == [
                .selectInputSource, .launch, .wait, .focusField,  // editor, first chunk
                .launch,  // terminal, first chunk: the only capture start
                .selectInputSource, .focusField,  // editor again: layout and field, no launch, no wait
                .selectInputSource, .focusField,  // editor a third time; terminal needs nothing
            ])
        #expect(activated.all == ["editor", "terminal", "editor", "terminal"])
    }

    @Test func failedReactivationFailsTheChunkWithoutTyping() async {
        let clock = ManualClock()
        let target = makeScenario(id: "t")
        let driver = FakeDriver()
        let runner = ScenarioRunner(
            driver: driver, readback: EchoReadback(), setup: FakeSetup(), probe: nil, clock: clock)
        let plan = SoakPlan.make(keystrokes: 32, targets: [target], seed: 1, chunkKeystrokes: 16)
        let summary = await SoakRunner(
            targets: [target], runner: runner, monitor: nil, clock: clock,
            activate: { _ in throw TestFailure.injected }
        )
        .run(plan)
        #expect(driver.typed.all.count == 1)
        #expect(summary.failures == [.init(chunk: 1, scenario: "t", outcome: .fail, reason: "activate: injected")])
        #expect(!summary.passed)
    }

    @Test func growthNeedsTwoDistinctTimes() {
        #expect(SoakSummary.growth([]) == nil)
        #expect(
            SoakSummary.growth([.init(elapsedSeconds: 5, megabytes: 1), .init(elapsedSeconds: 5, megabytes: 9)]) == nil)
        let flat = (0..<5).map { SoakSummary.Sample(elapsedSeconds: Double($0) * 3600, megabytes: 40) }
        #expect(SoakSummary.growth(flat) == 0)
    }
}

/// Returns the scenario's expected text, so every soak chunk passes.
private struct EchoReadback: ScenarioReadback {
    func currentText(of scenario: Scenario) async throws -> String { scenario.expect.text ?? "" }
}

@Suite struct PlatformBenchmarkTests {
    /// The gates are the 02-platform.md 8.1 "Gate" column (single source); a change here needs the spec.
    @Test func catalogueMatchesSection8_1() {
        let gates = Dictionary(uniqueKeysWithValues: PlatformGates.metrics.map { ($0.name, $0.gate) })
        #expect(
            gates == [
                "T2.p99": 3, "T3.p99": 15, "T4.p99": 10, "T5.flushes": 0, "T6.p95": 60, "C1.cpuPercent": 0.3,
                "C2.cpuPercent": 3, "M1.footprintMB": 50,
            ])
        #expect(PlatformGates.metric(named: "T1.p99") == nil)  // hosted pipeline benchmark (PLT-R820)
    }

    @Test func runnerProducesFormatVersion1WithCalibratedFalse() async throws {
        let source = ScriptedMetricSource(values: ["T2.p99": [2, 1, 3, 2, 9]])
        let report = await PlatformBenchmarkRunner(source: source, clock: ManualClock())
            .run(metrics: [PlatformGates.metric(named: "T2.p99")!], runs: 5)
        #expect(report.perRun.count == 5)
        #expect(report.unmeasured.isEmpty)
        let median = report.median
        #expect(median.formatVersion == 1 && median.benchmark == "platform" && median.runs == 5)
        #expect(median.metrics["T2.p99"] == .init(value: 2, unit: "ms", budget: 3, calibrated: false))
        #expect(median.calibration.name == "platform-reference-loop")
        #expect(median.calibration.nanoseconds >= 1)  // bench-compare rejects a non-positive calibration
        let json = try JSONSerialization.jsonObject(with: median.encoded()) as? [String: Any]
        #expect(json?["formatVersion"] as? Int == 1)
        let metric = (json?["metrics"] as? [String: Any])?["T2.p99"] as? [String: Any]
        #expect(metric?["calibrated"] as? Bool == false)
        #expect(metric?["budget"] as? Double == 3)
    }

    @Test func unavailableMetricsAreSkippedAndNamedInTheNote() async throws {
        let source = ScriptedMetricSource(values: ["C1.cpuPercent": [0.1]], unavailable: ["T2.p99"])
        let metrics = ["C1.cpuPercent", "T2.p99"].compactMap(PlatformGates.metric(named:))
        let report = await PlatformBenchmarkRunner(source: source, clock: ManualClock()).run(metrics: metrics, runs: 3)
        #expect(report.skipped == ["T2.p99": "needs the app export"])
        #expect(report.unmeasured.isEmpty)
        #expect(report.median.metrics.keys.sorted() == ["C1.cpuPercent"])
        #expect(report.median.note == "skipped, not measurable on this runner yet: T2.p99")
        #expect(source.calls.all.filter { $0 == "T2.p99" }.count == 1)  // not retried in later runs
        #expect(PlatformMetricUnavailable(reason: "x").description == "x")
    }

    @Test func medianOfEvenAndOddCounts() {
        #expect(BenchmarkDocument.median([3, 1, 2]) == 2)
        #expect(BenchmarkDocument.median([4, 1, 3, 2]) == 2.5)
        #expect(BenchmarkDocument.median(of: []) == nil)
    }

    @Test func realCalibrationLoopTakesTime() {
        #expect(PlatformBenchmarkRunner(source: ScriptedMetricSource(values: [:]), clock: MachClock()).calibrate() >= 1)
    }

    /// Packages/AppCore/Benchmarks/platform-baseline.json: ADR 0502 format, every gated metric present with its
    /// gate as budget, uncalibrated, and marked as a placeholder until the self-hosted runner measures it.
    @Test func committedPlatformBaselineMatchesTheCatalogue() throws {
        let url = repositoryRoot.appendingPathComponent("Packages/AppCore/Benchmarks/platform-baseline.json")
        let baseline = try JSONDecoder().decode(BenchmarkDocument.self, from: Data(contentsOf: url))
        #expect(baseline.formatVersion == 1 && baseline.benchmark == "platform")
        #expect(baseline.placeholder == true)
        #expect(baseline.calibration.nanoseconds > 0)
        #expect(baseline.referenceCalibration != nil)
        #expect(Set(baseline.metrics.keys) == Set(PlatformGates.metrics.map(\.name)))
        for metric in PlatformGates.metrics {
            let entry = try #require(baseline.metrics[metric.name])
            #expect(entry.budget == metric.gate && entry.unit == metric.unit, "\(metric.name)")
            #expect(entry.calibrated == false && entry.placeholder == true, "\(metric.name)")
            // Placeholder values sit at the gate, so the 25 % baseline check is never stricter than the gate.
            #expect(entry.value == metric.gate, "\(metric.name)")
        }
    }
}
