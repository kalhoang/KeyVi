// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Measurement plumbing of the live `compat-harness` commands (PLT-R821, PLT-R822, QA-R16, 13.7, section 9 canary):
// the bench source (process sampling plus the app's histograms and latency probe when the hooks answer), the soak
// monitor with the app's counters, the regression baseline, the privacy scan and the egress command.

internal import AppModel
internal import Foundation

/// Adds the app's own counters (integration hooks) to the live soak monitor.
struct HookedSoakMonitor: SoakMonitor {
    let base: any SoakMonitor
    let hooks: (any AppHookClient)?

    func footprintMegabytes() async throws -> Double { try await base.footprintMegabytes() }
    func heldModifierFlags() -> UInt64 { base.heldModifierFlags() }
    func counters() async -> SoakCounters? {
        guard let hooks, let snapshot = try? await hooks.state() else { return await base.counters() }
        return SoakCounters(snapshot)
    }
}

extension Harness {
    /// The committed baseline (`--baseline`, default perf/platform-baseline.json); nil when absent or unreadable.
    func loadBaseline() -> BenchmarkDocument? {
        let file = url(options.baseline ?? RegressionGate.baselinePath)
        guard let data = try? environment.fileSystem.readData(at: file, maxBytes: 1 << 20) else {
            environment.console.emitError("no baseline at " + file.path + ": only the gates apply")
            return nil
        }
        return try? JSONDecoder().decode(BenchmarkDocument.self, from: data)
    }

    /// Process sampling for C1, C2 and M1; with hooks also T2, T3, T5, T6 (workload) and T4 (latency probe).
    func benchSource(
        _ live: any LiveHarnessServices, targets: HarnessTargets, session: HarnessSession
    ) throws -> any PlatformMetricSource {
        let processes = try live.metricSource(options: options, targets: targets)
        guard let hooks = session.hooks else { return processes }
        return AppMetricSource(
            hooks: hooks, workload: benchWorkload(live, targets: targets, session: session),
            processSampling: processes)
    }

    /// Types `BenchWorkload` into TestHost at the normal profile under profile `bench-workload` (T5 is gated in
    /// the normal profile).
    func benchWorkload(
        _ live: any LiveHarnessServices, targets: HarnessTargets, session: HarnessSession
    ) -> AppMetricSource.Workload {
        let profile = session.profiles.profile(named: BenchWorkload.profileID)
        let configurator = session.configurator
        let keys = BenchWorkload.keys(keystrokes: options.workloadKeystrokes, seed: options.seed)
        let clock = environment.clock
        let seed = options.seed
        return {
            try await configurator?.apply(AppConfiguration(method: .telex, profile: profile))
            guard let testHost = targets.testHostBundleID else {
                throw HarnessSetupError.unresolvedTarget(HarnessTargets.testHostAlias)
            }
            let system = try live.systemActions(targets: targets)
            try await system.launch(testHost)
            try await system.resetTestHostFields(in: testHost)
            try await system.focusField(identifier: TestHostControls.mainTextField, in: testHost)
            try await PhysicalKeyboardDriver(sink: try live.keyEventSink(), clock: clock, seed: seed)
                .type(keys, profile: .normal)
        }
    }

    /// Scans what the app wrote during the run for the canaries.
    func privacyScan(_ evidence: any PrivacyEvidenceSource) async throws -> PrivacyReport {
        let report = PrivacyScanner().scan(
            files: try evidence.appWrittenFiles(), fileSystem: environment.fileSystem,
            log: try await evidence.unifiedLog())
        try write(try Self.json(report), to: (options.output ?? ".build/integration") + "/privacy-report.json")
        return report
    }

    // MARK: egress

    var egressHosts: [String] { options.allowHosts.isEmpty ? targets.siteHost.map { [$0] } ?? [] : options.allowHosts }

    func planEgress() -> HarnessExit {
        let hosts = options.phase == .production ? egressHosts.joined(separator: ", ") : "none (loopback only)"
        HarnessPlans.egressPlan(options: options, hosts: hosts, appUnderTest: targets.appUnderTestBundleID)
            .forEach(environment.console.emit)
        guard options.phase == .local || !egressHosts.isEmpty else {
            environment.console.emitError("compat-harness egress: no allowed host (scripts/brand.env APP_SITE_HOST)")
            return .failure
        }
        return .success
    }

    func runEgress() async -> HarnessExit {
        guard let live = requireLive("egress") else { return .incomplete }
        guard planEgress() == .success else { return .failure }
        do {
            guard let pid = try live.appControl(targets: targets).processIdentifier() else {
                environment.console.emitError("compat-harness egress: the app under test is not running")
                return .failure
            }
            await requestUpdateCheck(live)
            let report = await EgressMonitor(sampler: live.connectionSampler(), sleeper: environment.sleeper).run(
                processIdentifier: pid, phase: options.phase, allowedHosts: egressHosts,
                samples: options.minutes * 60 / options.intervalSeconds,
                intervalNanoseconds: UInt64(options.intervalSeconds) * 1_000_000_000)
            try write(
                try Self.json(report),
                to: options.output ?? ".build/integration/egress-" + options.phase.rawValue + ".json")
            for connection in report.connections where !connection.allowed {
                environment.console.emitError(
                    "not allowed: " + connection.endpoint.address + ":" + String(connection.endpoint.port))
            }
            environment.console.emit(
                "compat-harness egress: \(report.samples) sample(s), \(report.connections.count) endpoint(s), "
                    + (report.passed ? "passed" : "FAILED"))
            return report.passed ? .success : .failure
        } catch {
            environment.console.emitError("compat-harness egress: " + String(describing: error))
            return .failure
        }
    }

    /// 13.7 "a forced check": through the hooks when the app answers, otherwise the tester clicks it.
    private func requestUpdateCheck(_ live: any LiveHarnessServices) async {
        guard let folder = applicationSupport(library: live.libraryDirectory(), targets: targets) else { return }
        let channel = FileDropHookChannel(
            directory: FileDropHookChannel.directory(applicationSupport: folder), fileSystem: environment.fileSystem,
            clock: environment.clock, sleeper: environment.sleeper)
        do {
            _ = try await channel.accepted(.checkForUpdates)
        } catch {
            environment.console.emitError(
                "forced update check not sent (" + String(describing: error) + "); click Check for Updates now")
        }
    }
}
