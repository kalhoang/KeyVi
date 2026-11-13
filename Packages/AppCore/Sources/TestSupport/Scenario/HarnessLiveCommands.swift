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
    /// Privacy canary scan after a run that included canary scenarios (section 9 acceptance); nil otherwise.
    public var privacy: PrivacyReport?
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

    func scenarioServices(
        _ live: any LiveHarnessServices, targets: HarnessTargets, hooks: (any AppHookClient)? = nil
    ) throws -> LiveScenarioServices {
        let webDrivers = try WebDriverClients(
            endpoints: options.webDrivers, transport: live.httpTransport(), fallback: options.webDriverFallback)
        let captureFile = url(
            options.terminalCapture ?? (options.output ?? ".build/integration") + "/terminal-capture.txt")
        let terminal = ScenarioSetupRouter.TerminalCapture(fileSystem: environment.fileSystem, captureFile: captureFile)
        let system = try live.systemActions(targets: targets)
        let setup = ScenarioSetupRouter(
            system: system, targets: targets, webDrivers: webDrivers,
            terminal: terminal, sleeper: environment.sleeper, hooks: hooks)
        let readback = ReadbackRouter(
            targets: targets, ax: live.axReader(), webDrivers: webDrivers,
            terminal: TerminalCaptureReadback(fileSystem: environment.fileSystem, captureFile: captureFile),
            human: live.lineReader().map(HumanConfirmationReadback.init))
        return LiveScenarioServices(
            sink: try live.keyEventSink(), system: system, setup: setup, readback: readback,
            probe: live.stateProbe(targets: targets) ?? hooks.map(HookStateProbe.init))
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
            let session = try await openSession(live, targets: targets)
            let evidence = scenarios.contains { PrivacyCanary.isCanaryScenario($0.id) }
                ? try live.privacyEvidence(targets: targets, library: session.library) : nil
            let services = try scenarioServices(live, targets: targets, hooks: session.hooks)
            var results: [ScenarioResult] = []
            for original in scenarios {
                var scenario = targets.resolvingExpectation(of: original)
                if let profile = options.profile { scenario.timing = profile }
                let result = await run(scenario, services: services, session: session)
                environment.console.emit(
                    result.outcome.rawValue + " " + scenario.id + String(format: " (%.1f s)", result.durationSeconds)
                        + (result.reason.map { ": " + $0 } ?? ""))
                results.append(result)
            }
            await releaseSecureInput(after: scenarios, services: services, targets: targets)
            var privacy: PrivacyReport?
            if let evidence { privacy = try await privacyScan(evidence) }
            await close(session)
            return try finishRun(results, privacy: privacy)
        } catch {
            environment.console.emitError("compat-harness run: " + String(describing: error))
            return .failure
        }
    }

    /// Configures the app for the scenario, then runs it. A configuration failure fails only this scenario.
    func run(_ scenario: Scenario, services: LiveScenarioServices, session: HarnessSession) async -> ScenarioResult {
        do {
            try await session.configurator?.apply(AppConfiguration.of(scenario, profiles: session.profiles))
        } catch {
            return ScenarioResult(
                scenario: scenario.id, outcome: .fail, observedText: nil, durationSeconds: 0,
                reason: "configure app: " + String(describing: error))
        }
        return await runner(services, seed: SeededGenerator.seed(options.seed, scenario: scenario.id)).run(scenario)
    }

    func finishRun(_ results: [ScenarioResult], privacy: PrivacyReport?) throws -> HarnessExit {
        let report = ScenarioRunReport(
            profile: options.profile, seed: options.seed, passed: results.count { $0.outcome == .pass },
            failed: results.count { $0.outcome == .fail }, needsHuman: results.count { $0.outcome == .needsHuman },
            results: results, privacy: privacy)
        try write(
            try Self.json(report), to: options.report ?? (options.output ?? ".build/integration") + "/results.json")
        environment.console.emit(
            "compat-harness run: \(report.passed) passed, \(report.failed) failed, \(report.needsHuman) need a person"
        )
        if let privacy {
            environment.console.emit(
                "Privacy canary: \(privacy.scannedFiles) file(s), \(privacy.scannedLogBytes) log byte(s), "
                    + (privacy.passed ? "no canary found" : "FAILED"))
            for finding in privacy.findings {
                environment.console.emitError("canary in " + finding.location + " (" + finding.encoding + ")")
            }
            for file in privacy.unreadable { environment.console.emitError("not scanned: " + file) }
        }
        return report.failed == 0 && privacy?.passed != false ? .success : .failure
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
            let session = try await openSession(live, targets: resolved)
            let services = try scenarioServices(live, targets: resolved, hooks: session.hooks)
            var timed = targets
            for index in timed.indices { timed[index].timing = soakProfile }
            let plan = SoakPlan.make(
                keystrokes: options.keystrokes, targets: timed, seed: options.seed,
                chunkKeystrokes: options.chunkKeystrokes)
            let system = services.system
            let monitor = HookedSoakMonitor(base: try live.soakMonitor(targets: resolved), hooks: session.hooks)
            let soak = SoakRunner(
                targets: timed, runner: runner(services, seed: options.seed), monitor: monitor,
                clock: environment.clock,
                activate: { target in
                    guard let bundle = resolved.resolve(target.targetBundleId) else {
                        throw HarnessSetupError.unresolvedTarget(target.targetBundleId.rawValue)
                    }
                    try await system.launch(bundle)
                })
            let summary = await soak.run(plan)
            await close(session)
            return try finishSoak(summary)
        } catch {
            environment.console.emitError("compat-harness soak: " + String(describing: error))
            return .failure
        }
    }

    func finishSoak(_ summary: SoakSummary) throws -> HarnessExit {
        let directory = options.output ?? ".build/integration/soak"
        try write(try Self.json(summary), to: directory + "/soak-summary.json")
        environment.console.emit(
            "compat-harness soak: \(summary.keystrokes) keystrokes, \(summary.failures.count) failed chunk(s), growth "
                + (summary.growthMegabytesPerHour.map { String(format: "%.2f MB/h", $0) } ?? "not measured")
                + (summary.watchdogTrips.map { ", \($0) watchdog trip(s)" } ?? "")
                + (summary.appRestarted == true ? ", app restarted" : "") + (summary.passed ? ", passed" : ", FAILED"))
        guard let document = summary.metricsDocument() else { return summary.passed ? .success : .failure }
        try write(try document.encoded(), to: directory + "/soak-metrics.json")
        let verdicts = RegressionGate.evaluate(document, gates: [PlatformGates.soakGrowth], baseline: loadBaseline())
        verdicts.map(RegressionGate.describe).forEach(environment.console.emit)
        return summary.passed && !verdicts.contains(where: \.failed) ? .success : .failure
    }

    func runBench() async -> HarnessExit {
        guard let live = requireLive("bench") else { return .incomplete }
        let metrics = options.metrics.compactMap(PlatformGates.metric(named:))
        let targets = targets
        do {
            let session = try await openSession(live, targets: targets)
            let source = try benchSource(live, targets: targets, session: session)
            let report = await PlatformBenchmarkRunner(source: source, clock: environment.clock)
                .run(metrics: metrics, runs: options.runs)
            await close(session)
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

    /// PLT-R822: over the gate or more than 25 % above the baseline fails (RegressionGate; scripts/bench-compare.sh
    /// repeats the baseline comparison in CI). Metrics whose measurement failed make the run incomplete; metrics
    /// the source cannot measure (app histograms without the hooks build) are skipped with a warning.
    func benchVerdict(_ report: PlatformBenchmarkReport, metrics: [PlatformMetric]) -> HarnessExit {
        for metric in metrics {
            if let reason = report.skipped[metric.name] {
                environment.console.emitError("skipped: " + metric.name + " (" + reason + ")")
            } else if report.median.metrics[metric.name] == nil {
                environment.console.emitError(
                    "not measured: " + metric.name + " (" + (report.unmeasured[metric.name] ?? "no value") + ")")
            }
        }
        let verdicts = RegressionGate.evaluate(report.median, gates: metrics, baseline: loadBaseline())
        verdicts.map(RegressionGate.describe).forEach(environment.console.emit)
        if verdicts.contains(where: \.failed) { return .failure }
        return report.unmeasured.isEmpty ? .success : .incomplete
    }
}

extension HarnessExit {
    /// `incomplete` when the live services are missing, `failure` when loading failed.
    static func incompleteOrFailure(_ live: (any LiveHarnessServices)?) -> HarnessExit {
        live == nil ? .incomplete : .failure
    }
}
