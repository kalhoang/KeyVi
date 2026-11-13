// SPDX-License-Identifier: LicenseRef-App-Pending
//
// T2 to T6, C1, C2, M1, M2 (02-platform.md 8.1, PLT-R821, PLT-R822, ADR 0502): the committed placeholder baseline,
// the 25 % regression gate, the histogram and latency-probe metrics through the hooks, the process metrics
// procedure with ManualClock, and the soak's 13.6 counters. Every source is a fake.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

private func document(_ values: [String: Double], placeholder: Bool? = nil) -> BenchmarkDocument {
    BenchmarkDocument(
        formatVersion: 1, benchmark: "platform", runs: 1, calibration: .init(name: "c", nanoseconds: 1),
        metrics: values.mapValues {
            .init(value: $0, unit: "u", budget: nil, calibrated: false, placeholder: placeholder)
        })
}

private func gate(_ name: String, _ value: Double) -> PlatformMetric {
    PlatformMetric(name: name, unit: "u", gate: value, source: .harness, definition: "d")
}

@Suite struct PlatformBaselineFileTests {
    /// ADR 0502 formatVersion 1, every self-hosted 8.1 metric including M2, budget = gate, uncalibrated,
    /// placeholders equal to the gates until the runner measures (QA-R15).
    @Test func committedBaselineCoversEveryGateWithPlaceholders() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(RegressionGate.baselinePath))
        let baseline = try JSONDecoder().decode(BenchmarkDocument.self, from: data)
        #expect(baseline.formatVersion == 1 && baseline.benchmark == "platform" && baseline.placeholder == true)
        #expect(baseline.referenceCalibration != nil && baseline.calibration.nanoseconds > 0)
        #expect(Set(baseline.metrics.keys) == Set(PlatformGates.all.map(\.name)))
        for metric in PlatformGates.all {
            let stored = try #require(baseline.metrics[metric.name])
            #expect(
                stored.budget == metric.gate && stored.value == metric.gate && stored.unit == metric.unit,
                "\(metric.name)")
            #expect(stored.calibrated == false && stored.placeholder == true, "\(metric.name)")
        }
    }

    @Test func gateTableMatchesTheSpec() {
        let gates = Dictionary(uniqueKeysWithValues: PlatformGates.all.map { ($0.name, $0.gate) })
        #expect(
            gates == [
                "T2.p99": 3, "T3.p99": 15, "T4.p99": 10, "T5.flushes": 0, "T6.p95": 60, "C1.cpuPercent": 0.3,
                "C2.cpuPercent": 3, "M1.footprintMB": 50, "M2.growthMBPerHour": 5,
            ])
        #expect(PlatformGates.metric(named: "M2.growthMBPerHour") == nil)  // soak measures M2, bench does not
        #expect(PlatformGates.soakGrowth.source == .soak)
    }
}

@Suite struct RegressionGateTests {
    @Test func failsOverTheGateOrMoreThanAQuarterAboveTheBaseline() {
        let gates = [gate("a", 10), gate("b", 10), gate("c", 10), gate("d", 0), gate("e", 10), gate("f", 10)]
        let baseline = document(["a": 4, "b": 4, "c": 4, "d": 0, "f": 10])
        let result = document(["a": 5, "b": 5.04, "c": 10.5, "d": 0, "e": 9, "f": 9])
        let verdicts = RegressionGate.evaluate(result, gates: gates, baseline: baseline)
        #expect(verdicts.map(\.outcome) == [.ok, .regression, .overGate, .ok, .noBaseline, .ok])
        #expect(verdicts.map(\.failed) == [false, true, true, false, false, false])
        // A zero baseline has no relative change; one flush fails through its zero gate.
        #expect(
            RegressionGate.evaluate(document(["d": 1]), gates: [gate("d", 0)], baseline: baseline).first?.outcome
                == .overGate)
        #expect(RegressionGate.evaluate(result, gates: [gate("missing", 1)], baseline: nil).isEmpty)
    }

    @Test func describesPlaceholdersAndOutcomes() {
        let verdicts = RegressionGate.evaluate(
            document(["a": 2, "b": 6]), gates: [gate("a", 3), gate("b", 5)],
            baseline: document(["a": 3], placeholder: true))
        #expect(verdicts[0].baselineIsPlaceholder)
        #expect(RegressionGate.describe(verdicts[0]) == "a 2.000, gate 3.000, baseline 3.000 (placeholder): ok")
        #expect(RegressionGate.describe(verdicts[1]) == "b 6.000, gate 5.000, no baseline: OVER GATE")
        let regression = RegressionGate.evaluate(
            document(["a": 2]), gates: [gate("a", 3)], baseline: document(["a": 1]))
        #expect(RegressionGate.describe(regression[0]).hasSuffix("REGRESSION (more than 25 % above the baseline)"))
    }
}

@Suite struct AppMetricsTests {
    @Test func percentilesInterpolateInsideTheLog2Bucket() {
        var buckets = HistogramSnapshot.empty.buckets
        buckets[21] = 100  // 2.10 ms ... 4.19 ms
        let snapshot = HistogramSnapshot(buckets: buckets)
        let p99 = HistogramPercentile.nanoseconds(snapshot, 0.99)!
        #expect(abs(p99 - (2_097_152 + 2_097_152 * 0.99)) < 1)
        #expect(HistogramPercentile.nanoseconds(.empty, 0.99) == nil)
        #expect(HistogramPercentile.nanoseconds(snapshot, 1.5) == nil)
        var zero = HistogramSnapshot.empty.buckets
        zero[0] = 2
        #expect(HistogramPercentile.nanoseconds(HistogramSnapshot(buckets: zero), 0.5) == 1)
    }

    @Test func workloadKeysSwitchFocusEveryFewWords() {
        let keys = BenchWorkload.keys(keystrokes: 200, seed: 3)
        #expect(keys.count >= 200 && keys.first == "command+1")
        #expect(Set(keys.filter { $0.hasPrefix("command+") }) == Set(BenchWorkload.focusKeys))
        #expect(keys == BenchWorkload.keys(keystrokes: 200, seed: 3))
        #expect(throws: Never.self) { try ScenarioKeys.strokes(keys) }
    }

    /// One workload per run for all histogram metrics, after a metrics reset; T4 from the latency probe; C1 to M1
    /// from the process source; M2 left to the soak.
    @Test func batchRunsTheWorkloadOnceAndReadsEverySource() async throws {
        var metrics = emptyMetrics()
        var t2 = HistogramSnapshot.empty.buckets
        t2[20] = 10  // 1.05 to 2.10 ms
        metrics.decideToPosted = HistogramSnapshot(buckets: t2)
        metrics.focusRefresh = HistogramSnapshot(buckets: t2)
        metrics.flushes = 2
        var state = snapshot()
        state.metrics = metrics
        let probe = LatencyProbeResult(
            ranAt: Date(timeIntervalSince1970: 0),
            results: [
                .init(
                    profile: .normal, decideToPostedP50Microseconds: 1, decideToPostedP99Microseconds: 2,
                    endToEndDeltaP50Microseconds: 3, endToEndDeltaP99Microseconds: 4_500, samples: 9)
            ])
        let hooks = FakeHookClient(state: state, latency: probe)
        let workloads = Recorder<Int>()
        let source = AppMetricSource(
            hooks: hooks, workload: { workloads.append(1) },
            processSampling: ScriptedMetricSource(values: ["C1.cpuPercent": [0.1]]))
        let results = await source.measure(PlatformGates.all)
        #expect(workloads.all.count == 1)
        #expect(hooks.commands.all.prefix(2) == ["resetMetrics", "state"] && hooks.commands.all.last == "latencyProbe")
        #expect(try results["T2.p99"]?.get() ?? 0 > 1.0 && (try results["T2.p99"]?.get() ?? 9) < 2.1)
        #expect(try results["T5.flushes"]?.get() == 2)
        #expect(try results["T4.p99"]?.get() == 4.5)
        #expect(try results["C1.cpuPercent"]?.get() == 0.1)
        if case .failure(let error)? = results["T3.p99"] {
            #expect(error as? AppMetricError == .noSamples("T3.p99"))
        } else {
            Issue.record("T3 has no samples in this workload")
        }
        if case .failure(let error)? = results["M2.growthMBPerHour"] {
            #expect(error is PlatformMetricUnavailable)
        }
        #expect(try await source.measure(PlatformGates.metric(named: "T6.p95")!) > 1)
        #expect(AppMetricError.noSamples("T3.p99").description.contains("T3.p99"))
    }

    @Test func workloadOrHookFailuresFailOnlyTheirMetrics() async throws {
        let failing = AppMetricSource(
            hooks: FakeHookClient { _ in throw AppHookError.timeout(command: "x") }, workload: {},
            processSampling: ScriptedMetricSource(values: [:]))
        let results = await failing.measure([
            PlatformGates.metric(named: "T2.p99")!, PlatformGates.metric(named: "T4.p99")!,
        ])
        #expect(results.values.allSatisfy { if case .failure = $0 { true } else { false } })
        let noNormal = AppMetricSource(
            hooks: FakeHookClient(state: snapshot(), latency: LatencyProbeResult(ranAt: Date(), results: [])),
            workload: {}, processSampling: ScriptedMetricSource(values: [:]))
        await #expect(throws: AppHookError.missingPayload(command: "latencyProbe")) {
            try await noNormal.measure(PlatformGates.metric(named: "T4.p99")!)
        }
    }
}

@Suite struct ProcessMetricSourceTests {
    /// One 10-minute window per run: restart, wait 5 minutes, C1 over the next 5, M1 at the end; then C2.
    @Test func sharesTheSettleWindowBetweenC1AndM1() async throws {
        let clock = ManualClock()
        let origin = clock.now().nanoseconds
        let control = FakeAppControl()
        control.setRunning(true)
        let typed = Recorder<Int>()
        let source = ProcessMetricSource(
            sampling: FakeProcessSampling(cpuStep: 300_000_000, footprint: 40 * 1_048_576), control: control,
            typing: { seconds in
                typed.append(seconds)
                clock.advance(byMicroseconds: UInt64(seconds) * 1_000_000)
            }, clock: clock, sleeper: ClockSleeper(clock: clock),
            durations: .init(settleSeconds: 600, idleSeconds: 300, typingSeconds: 300))
        let results = await source.measure(PlatformGates.metrics)
        #expect(control.events.all == ["quit", "launch"])
        #expect(try results["M1.footprintMB"]?.get() == 40)
        #expect(abs((try results["C1.cpuPercent"]?.get() ?? 0) - 0.1) < 1e-9)  // 0.3 s of CPU in 300 s
        #expect(abs((try results["C2.cpuPercent"]?.get() ?? 0) - 0.1) < 1e-9)
        #expect(typed.all == [300] && clock.now().nanoseconds - origin == 900_000_000_000)
        if case .failure(let error)? = results["T2.p99"] { #expect(error is PlatformMetricUnavailable) }
        #expect(try await source.measure(PlatformGates.metric(named: "C2.cpuPercent")!) > 0)
        #expect(ProcessMetricSource.Durations(settleSeconds: 100, idleSeconds: 300).idleSeconds == 100)
    }
}

@Suite struct SoakCountersTests {
    private func summary(_ before: SoakCounters, _ after: SoakCounters?) -> SoakSummary {
        var summary = SoakSummary(
            keystrokes: 1, chunks: 1, failures: [], samples: [], growthMegabytesPerHour: 1, stuckModifierFlags: 0,
            passed: true)
        SoakRunner.record(before: before, after: after, into: &summary)
        return summary
    }

    @Test func recordsDeltasAndRestarts() {
        let start = SoakCounters(processIdentifier: 7, flushes: 2, watchdogTrips: 1)
        let same = summary(start, SoakCounters(processIdentifier: 7, flushes: 5, watchdogTrips: 1))
        #expect(same.flushes == 3 && same.watchdogTrips == 0 && same.appRestarted == false)
        #expect(summary(start, SoakCounters(processIdentifier: 8, flushes: 0, watchdogTrips: 0)).appRestarted == true)
        #expect(summary(start, nil).appRestarted == true)
        #expect(SoakCounters(snapshot(pid: 3)).processIdentifier == 3)
    }

    /// 13.6: a watchdog trip or a crash fails the soak; flushes fail it only in the normal profile.
    @Test func countersDecideTheVerdict() async {
        for (timing, after, passes) in [
            (Scenario.TimingProfile.fast, SoakCounters(processIdentifier: 1, flushes: 4, watchdogTrips: 0), true),
            (.normal, SoakCounters(processIdentifier: 1, flushes: 4, watchdogTrips: 0), false),
            (.fast, SoakCounters(processIdentifier: 1, flushes: 0, watchdogTrips: 1), false),
            (.fast, SoakCounters(processIdentifier: 2, flushes: 0, watchdogTrips: 0), false),
        ] {
            let clock = ManualClock()
            let monitor = CountingMonitor(
                counters: [SoakCounters(processIdentifier: 1, flushes: 0, watchdogTrips: 0), after])
            var target = makeScenario(id: "t", keys: ["a"])
            target.timing = timing
            let runner = ScenarioRunner(
                driver: FakeDriver(), readback: FakeReadback(result: .success("")), setup: FakeSetup(), probe: nil,
                clock: clock)
            let plan = SoakPlan(chunks: [SoakChunk(target: 0, keys: ["space"], expectedText: "")])
            let summary = await SoakRunner(targets: [target], runner: runner, monitor: monitor, clock: clock).run(plan)
            #expect(summary.passed == passes, "\(timing) \(after)")
        }
    }

    @Test func m2BecomesABenchmarkDocument() throws {
        let summary = SoakSummary(
            keystrokes: 1, chunks: 1, failures: [], samples: [], growthMegabytesPerHour: 1.5, stuckModifierFlags: 0,
            passed: true)
        let document = try #require(summary.metricsDocument())
        #expect(
            document.metrics["M2.growthMBPerHour"]?.value == 1.5 && document.metrics["M2.growthMBPerHour"]?.budget == 5)
        var unmeasured = summary
        unmeasured.growthMegabytesPerHour = nil
        #expect(unmeasured.metricsDocument() == nil)
    }
}

/// Soak monitor with scripted counters (first call, second call).
final class CountingMonitor: SoakMonitor, Sendable {
    private let values: Recorder<SoakCounters>
    private let calls = Recorder<Int>()
    init(counters: [SoakCounters]) {
        values = Recorder()
        counters.forEach(values.append)
    }
    func footprintMegabytes() async throws -> Double { 10 }
    func heldModifierFlags() -> UInt64 { 0 }
    func counters() async -> SoakCounters? {
        calls.append(1)
        let index = calls.all.count - 1
        return index < values.all.count ? values.all[index] : nil
    }
}
