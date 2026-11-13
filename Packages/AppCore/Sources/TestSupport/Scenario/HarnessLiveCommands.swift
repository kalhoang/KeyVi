// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Non-dry-run commands of `compat-harness`. They post physical-like events, launch apps and change input
// sources, so they run only on the self-hosted runner (QA-R12, QA-R13). Without live services (no
// `COMPAT_HARNESS_LIVE=1` in the environment, see `HarnessEnvironment.allowsLive`) they stop with
// `HarnessExit.incomplete` before doing anything.

internal import AppModel
internal import Foundation

/// `run` report written to `<output>/results.json` (or `--report`).
public struct ScenarioRunReport: Sendable, Hashable, Codable {
    public var formatVersion = 1
    public var profile: Scenario.TimingProfile?
    public var seed: UInt64
    public var passed: Int
    public var failed: Int
    public var needsHuman: Int
    public var results: [ScenarioResult]
}

/// Services shared by `run` and `soak`.
struct LiveScenarioServices {
    var sink: any KeyEventSink
    var system: any SystemActions
    var setup: ScenarioSetupRouter
    var readback: ReadbackRouter
    var probe: (any ScenarioStateProbe)?
}

extension Harness {
    func requireLive(_ command: String) -> (any LiveHarnessServices)? {
        guard let live = environment.live else {
            environment.console.emitError(
                "compat-harness " + command + ": live services are disabled on this machine (only the self-hosted "
                    + "runner sets " + HarnessEnvironment.liveOptInVariable + "=1); use --dry-run")
            return nil
        }
        return live
    }

    func scenarioServices(_ live: any LiveHarnessServices, targets: HarnessTargets) throws -> LiveScenarioServices {
        let webDrivers = try WebDriverClients(
            endpoints: options.webDrivers, transport: live.httpTransport(), fallback: options.webDriverFallback)
        let captureFile = url(
            options.terminalCapture ?? (options.output ?? ".build/integration") + "/terminal-capture.txt")
        let terminal = ScenarioSetupRouter.TerminalCapture(fileSystem: environment.fileSystem, captureFile: captureFile)
        let system = try live.systemActions(targets: targets)
        let setup = ScenarioSetupRouter(
            system: system, targets: targets, webDrivers: webDrivers,
            terminal: terminal, clock: environment.clock)
        let readback = ReadbackRouter(
            targets: targets, ax: live.axReader(), webDrivers: webDrivers,
            terminal: TerminalCaptureReadback(fileSystem: environment.fileSystem, captureFile: captureFile),
            human: live.lineReader().map(HumanConfirmationReadback.init))
        return LiveScenarioServices(
            sink: try live.keyEventSink(), system: system, setup: setup, readback: readback,
            probe: live.stateProbe(targets: targets))
    }

    func runner(_ services: LiveScenarioServices, seed: UInt64) -> ScenarioRunner {
        let driver = PhysicalKeyboardDriver(sink: services.sink, clock: environment.clock, seed: seed)
        return ScenarioRunner(
            driver: driver, readback: services.readback, setup: services.setup, probe: services.probe,
            clock: environment.clock)
    }

    func runScenarios() async -> HarnessExit {
        guard let live = requireLive("run"), let scenarios = selectedScenarios() else {
            return .incompleteOrFailure(environment.live)
        }
        let targets = targets
        do {
            let services = try scenarioServices(live, targets: targets)
            var results: [ScenarioResult] = []
            for original in scenarios {
                var scenario = targets.resolvingExpectation(of: original)
                if let profile = options.profile { scenario.timing = profile }
                let result = await runner(services, seed: SeededGenerator.seed(options.seed, scenario: scenario.id))
                    .run(scenario)
                environment.console.emit(
                    result.outcome.rawValue + " " + scenario.id + String(format: " (%.1f s)", result.durationSeconds)
                        + (result.reason.map { ": " + $0 } ?? ""))
                results.append(result)
            }
            await releaseSecureInput(after: scenarios, services: services, targets: targets)
            let report = ScenarioRunReport(
                profile: options.profile, seed: options.seed, passed: results.count { $0.outcome == .pass },
                failed: results.count { $0.outcome == .fail }, needsHuman: results.count { $0.outcome == .needsHuman },
                results: results)
            try write(
                try Self.json(report), to: options.report ?? (options.output ?? ".build/integration") + "/results.json")
            environment.console.emit(
                "compat-harness run: \(report.passed) passed, \(report.failed) failed, \(report.needsHuman) need a person"
            )
            return report.failed == 0 ? .success : .failure
        } catch {
            environment.console.emitError("compat-harness run: " + String(describing: error))
            return .failure
        }
    }

    /// A run that switched TestHost's secure-input holder on must not leave it on for the next job.
    func releaseSecureInput(after scenarios: [Scenario], services: LiveScenarioServices, targets: HarnessTargets) async
    {
        let usesHolder = scenarios.contains { scenario in
            scenario.targetBundleId.rawValue == HarnessTargets.testHostAlias
                && scenario.setup.contains { $0.action == .setSecureInput }
        }
        guard usesHolder, let testHost = targets.testHostBundleID else { return }
        try? await services.system.setSecureInput(false, in: testHost)
    }

    func runSoak() async -> HarnessExit {
        guard let live = requireLive("soak"), let targets = soakTargets() else {
            return .incompleteOrFailure(environment.live)
        }
        let resolved = self.targets
        do {
            let services = try scenarioServices(live, targets: resolved)
            var timed = targets
            for index in timed.indices { timed[index].timing = soakProfile }
            let plan = SoakPlan.make(
                keystrokes: options.keystrokes, targets: timed, seed: options.seed,
                chunkKeystrokes: options.chunkKeystrokes)
            let system = services.system
            let soak = SoakRunner(
                targets: timed, runner: runner(services, seed: options.seed),
                monitor: try live.soakMonitor(targets: resolved), clock: environment.clock,
                activate: { target in
                    guard let bundle = resolved.resolve(target.targetBundleId) else {
                        throw HarnessSetupError.unresolvedTarget(target.targetBundleId.rawValue)
                    }
                    try await system.launch(bundle)
                })
            let summary = await soak.run(plan)
            try write(try Self.json(summary), to: (options.output ?? ".build/integration/soak") + "/soak-summary.json")
            environment.console.emit(
                "compat-harness soak: \(summary.keystrokes) keystrokes, \(summary.failures.count) failed chunk(s), growth "
                    + (summary.growthMegabytesPerHour.map { String(format: "%.2f MB/h", $0) } ?? "not measured")
                    + (summary.passed ? ", passed" : ", FAILED"))
            return summary.passed ? .success : .failure
        } catch {
            environment.console.emitError("compat-harness soak: " + String(describing: error))
            return .failure
        }
    }

    func runBench() async -> HarnessExit {
        guard let live = requireLive("bench") else { return .incomplete }
        let metrics = options.metrics.compactMap(PlatformGates.metric(named:))
        do {
            let source = try live.metricSource(options: options, targets: targets)
            let report = await PlatformBenchmarkRunner(source: source, clock: environment.clock)
                .run(metrics: metrics, runs: options.runs)
            let output = options.output ?? ".build/integration/platform-bench.json"
            try write(try report.median.encoded(), to: output)
            for (index, run) in report.perRun.enumerated() {
                try write(try run.encoded(), to: output + ".runs/run-\(index + 1).json")
            }
            return benchVerdict(report, metrics: metrics)
        } catch {
            environment.console.emitError("compat-harness bench: " + String(describing: error))
            return .failure
        }
    }

    /// PLT-R822: a gated metric above its gate fails here, with no tolerance; the baseline comparison at 25 %
    /// is scripts/bench-compare.sh's job. Metrics whose measurement failed make the run incomplete; metrics the
    /// source cannot measure yet (app histograms before W2-E2's export) are skipped with a warning.
    func benchVerdict(_ report: PlatformBenchmarkReport, metrics: [PlatformMetric]) -> HarnessExit {
        var overGate = false
        for metric in metrics {
            if let reason = report.skipped[metric.name] {
                environment.console.emitError("skipped: " + metric.name + " (" + reason + ")")
                continue
            }
            guard let value = report.median.metrics[metric.name]?.value else {
                environment.console.emitError(
                    "not measured: " + metric.name + " (" + (report.unmeasured[metric.name] ?? "no value") + ")")
                continue
            }
            let verdict = value > metric.gate ? "OVER GATE" : "ok"
            overGate = overGate || value > metric.gate
            environment.console.emit(
                metric.name + String(format: " %.3f ", value) + metric.unit + ", gate \(metric.gate): " + verdict)
        }
        if overGate { return .failure }
        return report.unmeasured.isEmpty ? .success : .incomplete
    }
}

extension HarnessExit {
    /// `incomplete` when the live services are missing, `failure` when loading failed.
    static func incompleteOrFailure(_ live: (any LiveHarnessServices)?) -> HarnessExit {
        live == nil ? .incomplete : .failure
    }
}
