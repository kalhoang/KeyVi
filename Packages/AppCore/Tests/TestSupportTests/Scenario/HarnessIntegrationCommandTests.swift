// SPDX-License-Identifier: GPL-3.0-or-later
//
// The W2-E2 additions to compat-harness driven end to end with fakes: app configuration per scenario, the
// integration hooks (testHook steps, state probe, soak counters, bench histograms), the privacy canary scan after a
// run, the egress command and the baseline gate. No event leaves the process; the "app" is FakeHookApp over
// InMemoryFileSystem.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

private let support = RecordingLiveServices.library.appendingPathComponent("Application Support/Example App")
private let hooksDirectory = FileDropHookChannel.directory(applicationSupport: support)
private let testHost = "org.example.product.dev.testhost"

private func harness(
    _ arguments: [String], fileSystem: InMemoryFileSystem, live: (any LiveHarnessServices)?, clock: ManualClock,
    app: FakeHookApp? = nil
) throws -> (Harness, BufferedConsole) {
    var options = try HarnessCommandLine.parse(arguments)
    options.repository = "/repo"
    let console = BufferedConsole()
    let environment = HarnessEnvironment(
        fileSystem: fileSystem, console: console, clock: clock, sleeper: RespondingSleeper(app: app, clock: clock),
        live: live)
    return (Harness(options: options, environment: environment), console)
}

private func write(_ text: String, to path: String, in fileSystem: InMemoryFileSystem) throws {
    let url = URL(fileURLWithPath: path)
    try fileSystem.createDirectory(at: url.deletingLastPathComponent(), permissions: .ownerOnlyDirectory)
    try fileSystem.writeAtomically(Data(text.utf8), to: url, permissions: .ownerOnlyFile)
}

private let profileJSON = """
    {"id":"canary","summary":"s","scenarios":["testhost.privacyCanary.backspaceReplace"],
     "settings":{"restoreHotkey":{"type":"key","keyCode":53}}}
    """

@Suite struct HarnessW2E2OptionTests {
    @Test func newOptionsParse() throws {
        let options = try HarnessCommandLine.parse([
            "egress", "--phase", "local", "--minutes", "2", "--interval", "5", "--allow-hosts", "a.example, b.example",
            "--profiles", "p", "--no-configure", "--baseline", "b.json", "--workload-keys", "50", "--settle-seconds",
            "60", "--output", "/o/e.json",
        ])
        #expect(options.command == .egress && options.phase == .local && options.minutes == 2)
        #expect(options.intervalSeconds == 5 && options.allowHosts == ["a.example", "b.example"])
        #expect(options.profiles == "p" && !options.configureApp && options.baseline == "b.json")
        #expect(options.workloadKeystrokes == 50 && options.settleSeconds == 60)
        for bad in [
            ["egress", "--phase", "staging"], ["egress", "--minutes", "0"], ["bench", "--workload-keys", "x"],
        ] {
            #expect(throws: HarnessUsageError.self) { try HarnessCommandLine.parse(bad) }
        }
        #expect(HarnessCommandLine.usage.contains("egress") && HarnessCommandLine.usage.contains("--no-configure"))
    }

    /// `--only testhost.*` selects the TestHost suite (scripts/run-integration.sh `tests`).
    @Test func onlyAcceptsPrefixes() async throws {
        let fileSystem = try makeCheckout(scenarios: [
            "testhost.a.json": scenarioJSON(id: "testhost.a", target: HarnessTargets.testHostAlias),
            "testhost.b.json": scenarioJSON(id: "testhost.b", target: HarnessTargets.testHostAlias),
            "other.json": scenarioJSON(id: "other"),
        ])
        let (subject, console) = try harness(
            ["run", "--dry-run", "--only", "testhost.*"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await subject.execute() == .success)
        #expect(console.output.first?.hasPrefix("compat-harness run --dry-run: 2 scenario(s)") == true)
        #expect(Harness.matches("testhost.a", "testhost.a") && !Harness.matches("testhost.ab", "testhost.a"))
        let (unknown, unknownConsole) = try harness(
            ["run", "--dry-run", "--only", "nothing.*"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await unknown.execute() == .failure)
        #expect(unknownConsole.errors.first == "compat-harness: unknown scenario id(s) nothing.*")
    }

    @Test func egressIsLiveOnlyWithTheOptIn() throws {
        let options = try HarnessCommandLine.parse(["egress"])
        #expect(HarnessEnvironment.allowsLive(options: options, environment: ["COMPAT_HARNESS_LIVE": "1"]))
        #expect(!HarnessEnvironment.allowsLive(options: options, environment: [:]))
        let dry = try HarnessCommandLine.parse(["egress", "--dry-run"])
        #expect(!HarnessEnvironment.allowsLive(options: dry, environment: ["COMPAT_HARNESS_LIVE": "1"]))
    }

    @Test func brandFileGivesFolderAndSiteHost() {
        let targets = HarnessTargets.resolve(
            repository: URL(fileURLWithPath: "/r"),
            brandEnvironment: "APP_DISPLAY_NAME=\"Gõ Việt\"\nAPP_SLUG=\"goviet\"\nAPP_SITE_HOST=\"h.example\"\n")
        #expect(targets.storageFolderName == "goviet" && targets.siteHost == "h.example")
        let ascii = HarnessTargets.resolve(
            repository: URL(fileURLWithPath: "/r"), brandEnvironment: "APP_DISPLAY_NAME=Plain\n")
        #expect(ascii.storageFolderName == "Plain")
        let rules = Data(
            #"{"secureInputHints":[{"bundleId":"com.example.Term","hintKey":"term.secureKeyboardEntry"},{"bundleId":"com.example.Other","hintKey":"other.hint"}]}"#
                .utf8)
        #expect(HarnessTargets.secureKeyboardEntryApps(rulesData: rules) == [bundle("com.example.Term")])
        #expect(HarnessTargets.secureKeyboardEntryApps(rulesData: Data("x".utf8)).isEmpty)
    }

    /// PLT-R398C: the targets of a live command carry the Secure Keyboard Entry apps of the repository's
    /// compat/rules.json, so the live system actions press the app menu item instead of asking a person.
    @Test func repositoryTargetsListTheSecureKeyboardEntryApps() throws {
        var options = try HarnessCommandLine.parse(["run"])
        options.repository = repositoryRoot.path
        let environment = HarnessEnvironment(
            fileSystem: LocalFileSystem(), console: BufferedConsole(), clock: ManualClock(), live: nil)
        let apps = Harness(options: options, environment: environment).targets.secureKeyboardEntryApps
        #expect(apps.isSuperset(of: [bundle("com.apple.Terminal"), bundle("com.googlecode.iterm2")]))
        options.rules = "missing.json"
        #expect(Harness(options: options, environment: environment).targets.secureKeyboardEntryApps.isEmpty)
    }
}

@Suite struct HarnessW2E2DryRunTests {
    @Test func runPlanShowsTheConfigurationAndTheCanaryScan() async throws {
        let fileSystem = try makeCheckout(scenarios: [
            "testhost.privacyCanary.backspaceReplace.json": scenarioJSON(
                id: "testhost.privacyCanary.backspaceReplace", target: HarnessTargets.testHostAlias)
        ])
        try write(profileJSON, to: "/repo/compat/scenarios/profiles/canary.json", in: fileSystem)
        let live = RecordingLiveServices(clock: ManualClock())
        let (subject, console) = try harness(
            ["run", "--dry-run"], fileSystem: fileSystem, live: live, clock: ManualClock())
        #expect(await subject.execute() == .success, "\(console.errors)")
        #expect(console.output.contains("    app: telex + canary"))
        #expect(console.output.contains { $0.hasPrefix("Privacy canary: after the run, scan") })
        #expect(console.output.contains { $0.hasPrefix("App settings: each scenario's configuration") })
        #expect(live.calls.all.isEmpty)
    }

    /// Bad profiles fail the plan. A `testHook` step is part of the schema since W3-A, so it plans cleanly.
    @Test func runPlanFailsOnBadProfilesButAcceptsTestHooks() async throws {
        let hooked = scenarioJSON(id: "h", setup: #"[{"action":"testHook","value":"tapTimeout@1"}]"#)
        let fileSystem = try makeCheckout(scenarios: ["h.json": hooked])
        try write(
            #"{"id":"bad","summary":"s","scenarios":["nope"],"ruleOverrides":[{"id":"user.x","summary":"s","match":{},"actionFromRule":"none"}]}"#,
            to: "/repo/compat/scenarios/profiles/bad.json", in: fileSystem)
        let (subject, console) = try harness(
            ["run", "--dry-run"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await subject.execute() == .failure)
        #expect(console.errors.contains("compat-harness: bad: no scenario nope"))
        #expect(console.errors.contains("compat-harness: bad: no shipped rule none"))
        #expect(!console.errors.contains { $0.contains("h uses testHook") })
        #expect(ScenarioValidator.pendingSchemaActions.isEmpty)
        // An invalid profile file stops the dry run before planning.
        try write("[]", to: "/repo/compat/scenarios/profiles/bad.json", in: fileSystem)
        let (broken, brokenConsole) = try harness(
            ["run", "--dry-run"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await broken.execute() == .failure)
        #expect(brokenConsole.errors.first?.contains("not a JSON object") == true)
    }

    @Test func egressPlanNamesTheAllowedHosts() async throws {
        let fileSystem = try makeCheckout(scenarios: [:])
        let (production, console) = try harness(
            ["egress", "--dry-run"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await production.execute() == .success)
        #expect(console.output.contains("Allowed: loopback; hosts: updates.example.org"))
        let (local, localConsole) = try harness(
            ["egress", "--dry-run", "--phase", "local"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await local.execute() == .success)
        #expect(localConsole.output.contains("Allowed: loopback; hosts: none (loopback only)"))
        try write("APP_BUNDLE_ID_DEV=\"a.b.dev\"\n", to: "/repo/scripts/brand.env", in: fileSystem)
        let (missing, missingConsole) = try harness(
            ["egress", "--dry-run"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await missing.execute() == .failure)
        #expect(missingConsole.errors.first?.contains("no allowed host") == true)
    }

    @Test func benchPlanShowsTheBaselineAndTheGate() async throws {
        let fileSystem = try makeCheckout(scenarios: [:])
        try write(
            #"{"formatVersion":1,"benchmark":"platform","calibration":{"name":"c","nanoseconds":1},"metrics":{"C1.cpuPercent":{"value":0.3,"unit":"%","placeholder":true}}}"#,
            to: "/repo/perf/platform-baseline.json", in: fileSystem)
        let (subject, console) = try harness(
            ["bench", "--dry-run"], fileSystem: fileSystem, live: nil, clock: ManualClock())
        #expect(await subject.execute() == .success)
        #expect(
            console.output.contains {
                $0.contains("C1.cpuPercent: gate 0.3 %, source harness, baseline 0.3 (placeholder)")
            })
        #expect(console.output.contains { $0.contains("T2.p99: gate 3.0 ms, source appHistogram, baseline none") })
        #expect(
            console.output.contains {
                $0.hasPrefix("Gate: over the 8.1 gate, or more than 25 % above perf/platform-baseline.json")
            })
    }
}

@Suite struct HarnessW2E2LiveTests {
    /// The canary scenario runs on its profile, the hooks answer (probe, readiness), the scan finds a leak in a
    /// file the app wrote, the report carries it, the run fails, and the app's settings are restored.
    @Test func runConfiguresProbesAndScansForCanaries() async throws {
        let id = "testhost.privacyCanary.backspaceReplace"
        let fileSystem = try makeCheckout(scenarios: [
            id + ".json": scenarioJSON(
                id: id, target: HarnessTargets.testHostAlias,
                setup: #"[{"action":"focusField","value":"testhost.native.textField"}]"#
            ).replacingOccurrences(of: #"{"text":"đi"}"#, with: #"{"text":"đi","paused":false}"#)
        ])
        try write(profileJSON, to: "/repo/compat/scenarios/profiles/canary.json", in: fileSystem)
        try write(#"{"event":"kanaryzqx"}"#, to: "/library/Logs/Example App/app.jsonl", in: fileSystem)
        let clock = ManualClock()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let evidence = FakePrivacyEvidence(
            files: [URL(fileURLWithPath: "/library/Logs/Example App/app.jsonl")], log: "")
        let live = RecordingLiveServices(clock: clock, axText: "đi", evidence: evidence)
        let (subject, console) = try harness(
            ["run", "--output", "/out"], fileSystem: fileSystem, live: live, clock: clock, app: app)
        #expect(await subject.execute() == .failure)
        #expect(console.output.contains("Integration hooks: answering"))
        #expect(console.output.contains { $0.hasPrefix("pass " + id) })
        #expect(console.output.contains { $0.contains("Privacy canary: 1 file(s)") && $0.hasSuffix("FAILED") })
        #expect(console.errors.contains("canary in /library/Logs/Example App/app.jsonl (utf8-nfc)"))
        let report = try JSONDecoder().decode(
            ScenarioRunReport.self,
            from: fileSystem.readData(at: URL(fileURLWithPath: "/out/results.json"), maxBytes: 1 << 20))
        #expect(report.privacy?.passed == false && report.passed == 1)
        #expect(fileSystem.fileExists(at: URL(fileURLWithPath: "/out/privacy-report.json")))
        // factory, then the canary profile, then the restore; each a quit and a launch after the first.
        #expect(live.control.events.all == ["launch", "quit", "launch", "quit", "launch"])
        #expect(app.commands.all.filter { $0 == "state" }.count >= 3)
        #expect(!fileSystem.fileExists(at: support.appendingPathComponent("settings.json")))  // restored: none before
    }

    /// A configuration that cannot be written fails only its scenario, with the reason.
    @Test func configurationFailureFailsTheScenario() async throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        try write(
            #"{"id":"p","summary":"s","scenarios":["a"],"ruleOverrides":[{"id":"user.x","summary":"s","match":{},"actionFromRule":"missing"}]}"#,
            to: "/repo/compat/scenarios/profiles/p.json", in: fileSystem)
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let (subject, console) = try harness(["run"], fileSystem: fileSystem, live: live, clock: clock)
        #expect(await subject.execute() == .failure)
        #expect(
            console.output.contains {
                $0.hasPrefix("fail a") && $0.contains("configure app: profile p copies unknown rule missing")
            })
    }

    /// `--no-configure` leaves the app alone; a testHook step without the hooks build needs a person.
    @Test func noConfigureAndMissingHooks() async throws {
        let fileSystem = try makeCheckout(scenarios: [
            "a.json": scenarioJSON(id: "a", setup: #"[{"action":"testHook","value":"tapTimeout"}]"#)
        ])
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let (subject, console) = try harness(
            ["run", "--no-configure"], fileSystem: fileSystem, live: live, clock: clock)
        #expect(await subject.execute() == .success)
        #expect(console.output.contains { $0.hasPrefix("needsHuman a") && $0.contains("INTEGRATION_HOOKS test build") })
        #expect(live.control.events.all.isEmpty)
        #expect(console.output.contains { $0.hasPrefix("Integration hooks: not answering") })
    }

    /// With the hooks: a testHook step fires, and a revoked permission is restored after the scenario.
    @Test func testHookStepsReachTheApp() async throws {
        let fileSystem = try makeCheckout(scenarios: [
            "a.json": scenarioJSON(id: "a", setup: #"[{"action":"testHook","value":"revokePermission@1"}]"#)
        ])
        // Files a killed run left behind are cleared when the session opens (PLT-R821).
        let stale = hooksDirectory.path
        try write(
            #"{"formatVersion":1,"sequence":5,"command":"tapTimeout"}"#, to: stale + "/request-5.json", in: fileSystem)
        try write(#"{"formatVersion":1,"sequence":5,"ok":true}"#, to: stale + "/response-5.json", in: fileSystem)
        let clock = ManualClock()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let (subject, _) = try harness(["run"], fileSystem: fileSystem, live: live, clock: clock, app: app)
        #expect(await subject.execute() == .success)
        let commands = app.commands.all.filter { $0 != "state" }
        #expect(commands == ["revokePermission", "restorePermission"])
        #expect(live.sink.records.count == 6)
        #expect(try fileSystem.contentsOfDirectory(at: hooksDirectory).isEmpty)
    }

    /// ADR 0502 (app profiles): an error after the session opened still restores the app's own settings, so the
    /// runner never keeps the harness configuration and the next run never backs it up as the original.
    @Test(arguments: [
        ["run", "--output", "/out"], ["soak", "--keystrokes", "32", "--targets", "a", "--output", "/out/soak"],
        ["bench", "--runs", "1", "--metrics", "C1.cpuPercent", "--output", "/out/b.json"],
    ])
    func settingsAreRestoredWhenALiveCommandFails(_ arguments: [String]) async throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        let original = Data(#"{"original":true}"#.utf8)
        try fileSystem.createDirectory(at: support, permissions: .ownerOnlyDirectory)
        try fileSystem.writeAtomically(
            original, to: support.appendingPathComponent("settings.json"), permissions: .ownerOnlyFile)
        let clock = ManualClock()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        // run: the key sink cannot be created; soak: no soak monitor; bench: no metric source.
        let live = RecordingLiveServices(clock: clock, axText: "đi", failing: ["sink"])
        let (subject, console) = try harness(arguments, fileSystem: fileSystem, live: live, clock: clock, app: app)
        #expect(await subject.execute() == .failure)
        #expect(console.errors.contains { $0.contains("injected") })
        #expect(live.control.events.all == ["launch", "quit", "launch"])  // factory, then the restore
        let restored = try fileSystem.readData(at: support.appendingPathComponent("settings.json"), maxBytes: 1 << 20)
        #expect(restored == original)
        #expect(!fileSystem.fileExists(at: support.appendingPathComponent("rule-overrides.json")))
    }

    /// A factory configuration whose app never becomes ready puts the original settings back before failing.
    @Test func settingsAreRestoredWhenTheFactoryConfigurationFails() async throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        let original = Data(#"{"original":true}"#.utf8)
        try fileSystem.createDirectory(at: support, permissions: .ownerOnlyDirectory)
        try fileSystem.writeAtomically(
            original, to: support.appendingPathComponent("settings.json"), permissions: .ownerOnlyFile)
        let clock = ManualClock()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory, state: snapshot(.starting))
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let (subject, console) = try harness(["run"], fileSystem: fileSystem, live: live, clock: clock, app: app)
        #expect(await subject.execute() == .failure)
        #expect(console.errors.contains { $0.hasPrefix("compat-harness run: ") })
        #expect(live.control.events.all == ["launch", "quit", "launch"])
        let restored = try fileSystem.readData(at: support.appendingPathComponent("settings.json"), maxBytes: 1 << 20)
        #expect(restored == original)
    }

    /// PLT-R398C: a setSecureInput step on a Secure Keyboard Entry app reaches the live system actions with
    /// targets that name the app, so `LiveSystemActions` presses its menu item (no needsHuman).
    @Test func secureKeyboardEntryAppsReachTheSystemActions() async throws {
        let rules = #"{"secureInputHints":[{"bundleId":"com.example.Term","hintKey":"term.secureKeyboardEntry"}]}"#
        let fileSystem = try makeCheckout(
            scenarios: [
                "a.json": scenarioJSON(
                    id: "a", target: "com.example.Term", setup: #"[{"action":"setSecureInput","value":"on"}]"#)
            ], rules: rules)
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let (subject, console) = try harness(
            ["run", "--no-configure"], fileSystem: fileSystem, live: live, clock: clock)
        #expect(await subject.execute() == .success)
        #expect(live.systemTargets.all.map(\.secureKeyboardEntryApps) == [[bundle("com.example.Term")]])
        #expect(live.system.calls.all.contains("secure true in com.example.Term"))
        #expect(console.output.contains { $0.hasPrefix("pass a") })
    }

    @Test func egressSamplesTheRunningApp() async throws {
        let fileSystem = try makeCheckout(scenarios: [:])
        let clock = ManualClock()
        let sampler = FakeConnectionSampler(
            samples: [[EgressEndpoint(address: "203.0.113.5", port: 443, transport: "TCP")]],
            addresses: ["updates.example.org": ["203.0.113.5"]])
        let live = RecordingLiveServices(clock: clock, sampler: sampler)
        live.control.setRunning(true)
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let (subject, console) = try harness(
            ["egress", "--minutes", "1", "--interval", "30", "--output", "/out/e.json"], fileSystem: fileSystem,
            live: live, clock: clock, app: app)
        #expect(await subject.execute() == .success)
        #expect(app.commands.all == ["checkForUpdates"])
        #expect(console.output.last == "compat-harness egress: 1 sample(s), 1 endpoint(s), passed")
        // A live run never prints the dry-run plan (QA-R13: the artefact log tells the two apart).
        #expect(console.output.first == "compat-harness egress: phase production, 1 minute(s), sampling pid 100")
        #expect(!console.output.contains { $0.contains("plan only") })
        let report = try JSONDecoder().decode(
            EgressReport.self, from: fileSystem.readData(at: URL(fileURLWithPath: "/out/e.json"), maxBytes: 1 << 20))
        #expect(report.passed && report.allowedHosts == ["updates.example.org"])
        // Not running: nothing to sample. Unknown host: fails and names it.
        live.control.setRunning(false)
        let (stopped, stoppedConsole) = try harness(["egress"], fileSystem: fileSystem, live: live, clock: clock)
        #expect(await stopped.execute() == .failure)
        #expect(stoppedConsole.errors.last == "compat-harness egress: the app under test is not running")
        live.control.setRunning(true)
        let leaking = RecordingLiveServices(
            clock: clock,
            sampler: FakeConnectionSampler(samples: [
                [EgressEndpoint(address: "198.51.100.1", port: 80, transport: "TCP")]
            ]))
        leaking.control.setRunning(true)
        let (leak, leakConsole) = try harness(
            ["egress", "--minutes", "1", "--interval", "60"], fileSystem: fileSystem, live: leaking, clock: clock)
        #expect(await leak.execute() == .failure)
        #expect(leakConsole.errors.contains("not allowed: 198.51.100.1:80"))
        #expect(leakConsole.errors.contains { $0.hasPrefix("forced update check not sent") })
        let (offline, _) = try harness(["egress"], fileSystem: fileSystem, live: nil, clock: clock)
        #expect(await offline.execute() == .incomplete)
    }

    /// Bench with the hooks: histogram metrics come from the app after the TestHost workload; the baseline gate
    /// fails a metric more than 25 % above it.
    @Test func benchReadsTheAppAndGatesAgainstTheBaseline() async throws {
        let fileSystem = try makeCheckout(scenarios: [:])
        try write(
            #"{"formatVersion":1,"benchmark":"platform","calibration":{"name":"c","nanoseconds":1},"metrics":{"T5.flushes":{"value":0,"unit":"count"},"C1.cpuPercent":{"value":0.1,"unit":"%"}}}"#,
            to: "/repo/perf/platform-baseline.json", in: fileSystem)
        let clock = ManualClock()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let live = RecordingLiveServices(clock: clock, metrics: ScriptedMetricSource(values: ["C1.cpuPercent": [0.2]]))
        let (subject, console) = try harness(
            [
                "bench", "--runs", "1", "--metrics", "T5.flushes,C1.cpuPercent", "--workload-keys", "10", "--output",
                "/out/b.json",
            ],
            fileSystem: fileSystem, live: live, clock: clock, app: app)
        #expect(await subject.execute() == .failure)  // C1 0.2 is 100 % above the 0.1 baseline
        #expect(console.output.contains("T5.flushes 0.000, gate 0.000, baseline 0.000: ok"))
        #expect(console.output.contains { $0.hasPrefix("C1.cpuPercent 0.200") && $0.contains("REGRESSION") })
        #expect(app.commands.all.contains("resetMetrics"))
        #expect(live.system.calls.all.contains("focus testhost.native.textField in " + testHost))
        #expect(live.sink.records.count >= 20)
    }

    /// Soak with the hooks: the counters reach the summary.
    @Test func soakRecordsTheAppCounters() async throws {
        let clock = ManualClock()
        let fileSystem = try makeCheckout(scenarios: [
            "t.json": scenarioJSON(id: "t", target: HarnessTargets.testHostAlias)
        ])
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let live = RecordingLiveServices(
            clock: clock, axText: "x", monitor: ScriptedSoakMonitor(footprints: [30], clock: clock))
        let (subject, console) = try harness(
            ["soak", "--keystrokes", "32", "--chunk", "16", "--targets", "t", "--output", "/out/soak"],
            fileSystem: fileSystem, live: live, clock: clock, app: app)
        _ = await subject.execute()
        let summary = try JSONDecoder().decode(
            SoakSummary.self,
            from: fileSystem.readData(at: URL(fileURLWithPath: "/out/soak/soak-summary.json"), maxBytes: 1 << 20))
        #expect(summary.watchdogTrips == 0 && summary.flushes == 0 && summary.appRestarted == false)
        #expect(console.output.contains { $0.contains("0 watchdog trip(s)") })
    }
}
