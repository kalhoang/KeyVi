// SPDX-License-Identifier: GPL-3.0-or-later
//
// compat-harness command line, dry runs (the only mode allowed on a developer Mac), coverage, and the live
// commands driven entirely by recording fakes (no event leaves the process).

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct HarnessCommandLineTests {
    @Test func ciCommandLinesParse() throws {
        // scripts/run-integration.sh and ADR 0502.
        let run = try HarnessCommandLine.parse(["run", "--scenarios", "compat/scenarios", "--output", "/o/compat"])
        #expect(run.command == .run && run.scenarios == "compat/scenarios" && run.output == "/o/compat" && !run.dryRun)
        let soak = try HarnessCommandLine.parse(["soak", "--keystrokes", "1000000", "--output", "/o/soak"])
        #expect(soak.command == .soak && soak.keystrokes == 1_000_000)
        let bench = try HarnessCommandLine.parse(["bench", "--runs", "5", "--output", "/o/b.json", "--dry-run"])
        #expect(bench.command == .bench && bench.runs == 5 && bench.output == "/o/b.json" && bench.dryRun)
    }

    @Test func everyOptionParses() throws {
        let options = try HarnessCommandLine.parse([
            "run", "--repository", "/r", "--rules", "r.json", "--report", "x.json", "--profile", "burst", "--only",
            "a, b",
            "--seed", "9", "--testhost-bundle-id", "a.b", "--app-bundle-id", "c.d", "--terminal-capture", "/t",
            "--webdriver", "com.example.Browser=http://127.0.0.1:4444", "--targets", "x,y", "--chunk", "20",
            "--metrics", "C1.cpuPercent,M1.footprintMB", "--idle-seconds", "2", "--typing-seconds", "3", "--keystrokes",
            "16",
        ])
        #expect(options.repository == "/r" && options.rules == "r.json" && options.report == "x.json")
        #expect(options.profile == .burst && options.only == ["a", "b"] && options.seed == 9)
        #expect(options.testHostBundleID == "a.b" && options.appBundleID == "c.d" && options.terminalCapture == "/t")
        #expect(options.webDrivers == [bundle("com.example.Browser"): URL(string: "http://127.0.0.1:4444")!])
        #expect(options.targets == ["x", "y"] && options.chunkKeystrokes == 20 && options.keystrokes == 16)
        #expect(
            options.metrics == ["C1.cpuPercent", "M1.footprintMB"] && options.idleSeconds == 2
                && options.typingSeconds == 3)
    }

    @Test func helpForms() throws {
        #expect(try HarnessCommandLine.parse([]).command == .help)
        #expect(try HarnessCommandLine.parse(["-h"]).command == .help)
        #expect(try HarnessCommandLine.parse(["run", "--help"]).command == .help)
        #expect(try HarnessCommandLine.parse(["coverage"]).command == .coverage)
    }

    @Test(arguments: [
        ["launch"], ["run", "--output"], ["run", "--bogus", "x"], ["run", "--profile", "slow"],
        ["soak", "--keystrokes", "15"],
        ["bench", "--runs", "0"], ["bench", "--metrics", "T9.p99"],
        ["run", "--app-bundle-id", "sha256:" + String(repeating: "a", count: 64)],
        ["run", "--testhost-bundle-id", "not valid"], ["run", "--webdriver", "nobundle"],
        ["run", "--webdriver", "a.b=nourl"],
        ["run", "--seed", "-1"],
    ])
    func usageErrors(arguments: [String]) {
        #expect(throws: HarnessUsageError.self) { try HarnessCommandLine.parse(arguments) }
    }

    @Test func usageMentionsEveryCommandAndDryRun() {
        for word in ["run", "soak", "bench", "coverage", "--dry-run", "--webdriver", "--keystrokes"] {
            #expect(HarnessCommandLine.usage.contains(word))
        }
        #expect(HarnessUsageError("x").description == "x")
    }
}

/// Builds a harness over an in-memory checkout at /repo.
private func harness(
    _ arguments: [String], fileSystem: InMemoryFileSystem, live: (any LiveHarnessServices)? = nil,
    clock: ManualClock = ManualClock()
) throws -> (Harness, BufferedConsole) {
    var options = try HarnessCommandLine.parse(arguments)
    options.repository = "/repo"
    let console = BufferedConsole()
    let environment = HarnessEnvironment(fileSystem: fileSystem, console: console, clock: clock, live: live)
    return (Harness(options: options, environment: environment), console)
}

private let rulesJSON = """
    {"rules":[{"id":"r.one","test":{"scenario":"a","automation":"automated"}},
              {"id":"r.two","test":{"scenario":"missing.one","automation":"manual"}},
              {"id":"r.three","test":{}},
              {"summary":"no id"}]}
    """

@Suite struct HarnessDryRunTests {
    @Test func runDryRunPrintsThePlanAndNeverTouchesLiveServices() async throws {
        let live = RecordingLiveServices(clock: ManualClock())
        let fileSystem = try makeCheckout(scenarios: [
            "a.json": scenarioJSON(id: "a", target: HarnessTargets.testHostAlias),
            "b.json": scenarioJSON(id: "b", setup: #"[{"action":"openURL","value":"{pages}/fields.html"}]"#),
        ])
        let (harness, console) = try harness(
            ["run", "--dry-run", "--profile", "fast"], fileSystem: fileSystem, live: live)
        #expect(await harness.execute() == .success)
        let text = console.output.joined(separator: "\n")
        #expect(text.contains("2 scenario(s)"))
        #expect(text.contains("- a\n    target org.example.product.dev.testhost"))
        #expect(text.contains("timing fast"))
        #expect(text.contains("openURL file:///repo/TestHost/Resources/Pages/fields.html"))
        #expect(text.contains("keys: 3 keystroke(s), 6 event(s)"))
        #expect(text.contains("expect: text \u{201C}đi\u{201D}"))
        #expect(text.contains("Total: 2 scenario(s), 6 keystroke(s)"))
        #expect(live.calls.all.isEmpty)
        #expect(live.sink.records.isEmpty)
    }

    @Test func dryRunFailsOnInvalidScenariosAndUnknownOnlyIDs() async throws {
        let broken = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "b")])
        let (first, console) = try harness(["run", "--dry-run"], fileSystem: broken)
        #expect(await first.execute() == .failure)
        #expect(console.errors.first?.contains("a.json") == true)
        let valid = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        let (second, errors) = try harness(["run", "--dry-run", "--only", "a,zzz"], fileSystem: valid)
        #expect(await second.execute() == .failure)
        #expect(errors.errors == ["compat-harness: unknown scenario id(s) zzz"])
        let (third, onlyConsole) = try harness(["run", "--dry-run", "--only", "a"], fileSystem: valid)
        #expect(await third.execute() == .success)
        #expect(onlyConsole.output.first?.contains("1 scenario(s)") == true)
    }

    @Test func dryRunReportsUnresolvedTestHostAndRuleGaps() async throws {
        let fileSystem = try makeCheckout(
            scenarios: ["a.json": scenarioJSON(id: "a", target: HarnessTargets.testHostAlias)], rules: rulesJSON)
        try fileSystem.removeItem(at: URL(fileURLWithPath: "/repo/scripts/brand.env"))
        let (harness, console) = try harness(["run", "--dry-run"], fileSystem: fileSystem)
        #expect(await harness.execute() == .failure)
        let text = console.output.joined(separator: "\n")
        #expect(text.contains("unresolved (scripts/brand.env missing)"))
        #expect(text.contains("2 of 3 rule(s) have no scenario file"))
        #expect(console.errors == ["compat-harness: unresolved target in a"])
    }

    @Test func soakDryRunPlansExactlyTheKeystrokes() async throws {
        let live = RecordingLiveServices(clock: ManualClock())
        let fileSystem = try makeCheckout(scenarios: [
            "t.json": scenarioJSON(id: "t", target: HarnessTargets.testHostAlias),
            "term.json": scenarioJSON(id: "term", target: "com.example.Terminal", readback: "terminalCapture"),
        ])
        let (harness, console) = try harness(
            ["soak", "--dry-run", "--keystrokes", "1000", "--targets", "t,term", "--chunk", "100"],
            fileSystem: fileSystem,
            live: live)
        #expect(await harness.execute() == .success)
        let text = console.output.joined(separator: "\n")
        #expect(text.contains("1000 keystroke(s) in 10 chunk(s), profile fast"))
        #expect(text.contains("t: org.example.product.dev.testhost, readback ax, 5 chunk(s), 500 keystroke(s)"))
        #expect(text.contains("term: com.example.Terminal, readback terminalCapture, 5 chunk(s), 500 keystroke(s)"))
        #expect(text.contains("App under test: org.example.product.dev"))
        #expect(live.calls.all.isEmpty)
    }

    @Test func soakNeedsExistingTelexTargets() async throws {
        let fileSystem = try makeCheckout(scenarios: [
            "v.json": scenarioJSON(id: "v").replacingOccurrences(of: #""telex""#, with: #""vni""#)
        ])
        let (missing, console) = try harness(["soak", "--dry-run", "--targets", "nope"], fileSystem: fileSystem)
        #expect(await missing.execute() == .failure)
        #expect(console.errors.first?.contains("--targets") == true)
        let (vni, _) = try harness(["soak", "--dry-run", "--targets", "v"], fileSystem: fileSystem)
        #expect(await vni.execute() == .failure)
        let broken = try makeCheckout(scenarios: ["x.json": "{"])
        let (unreadable, _) = try harness(["soak", "--dry-run", "--targets", "x"], fileSystem: broken)
        #expect(await unreadable.execute() == .failure)
    }

    @Test func benchDryRunListsTheGates() async throws {
        let live = RecordingLiveServices(clock: ManualClock())
        let (harness, console) = try harness(
            ["bench", "--dry-run", "--runs", "5", "--output", "/o/b.json"],
            fileSystem: try makeCheckout(scenarios: [:]),
            live: live)
        #expect(await harness.execute() == .success)
        let text = console.output.joined(separator: "\n")
        #expect(text.contains("median of 5 run(s), output /o/b.json"))
        #expect(text.contains("T2.p99: gate 3.0 ms, source appHistogram"))
        #expect(text.contains("C2.cpuPercent: gate 3.0 %, source harness"))
        #expect(live.calls.all.isEmpty)
    }

    @Test func helpPrintsUsage() async throws {
        let (harness, console) = try harness(["help"], fileSystem: InMemoryFileSystem())
        #expect(await harness.execute() == .success)
        #expect(console.output == [HarnessCommandLine.usage])
    }
}

@Suite struct HarnessCoverageTests {
    @Test func listsRulesWithoutScenarios() async throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")], rules: rulesJSON)
        let (harness, console) = try harness(["coverage"], fileSystem: fileSystem)
        #expect(await harness.execute() == .failure)
        #expect(
            console.output == [
                "Rule coverage (compat/rules.json): 2 of 3 rule(s) have no scenario file",
                "  missing: r.two -> missing compat/scenarios/missing.one.json",
                "  missing: r.three -> no test.scenario",
            ])
    }

    @Test func completeCoverageAndMissingRulesFilePass() async throws {
        let complete = try makeCheckout(
            scenarios: ["a.json": scenarioJSON(id: "a")], rules: #"{"rules":[{"id":"r","test":{"scenario":"a"}}]}"#)
        let (first, console) = try harness(["coverage"], fileSystem: complete)
        #expect(await first.execute() == .success)
        #expect(console.output == ["Rule coverage (compat/rules.json): all 1 rule(s) have a scenario"])
        let (second, notice) = try harness(["coverage"], fileSystem: try makeCheckout(scenarios: [:]))
        #expect(await second.execute() == .success)
        #expect(notice.output.first?.contains("not found") == true)
    }

    @Test func malformedRulesFileFails() async throws {
        let fileSystem = try makeCheckout(scenarios: [:], rules: #"{"schemaVersion":1}"#)
        let (harness, console) = try harness(["coverage"], fileSystem: fileSystem)
        #expect(await harness.execute() == .failure)
        #expect(console.errors.first?.contains("notARulesDocument") == true)
    }

    @Test func gapDescriptions() throws {
        let gaps = try RuleScenarioCoverage.gaps(rulesData: Data(rulesJSON.utf8), scenarioIDs: ["a"])
        #expect(
            gaps == [
                RuleScenarioGap(ruleID: "r.two", scenario: "missing.one"),
                RuleScenarioGap(ruleID: "r.three", scenario: nil),
            ])
        #expect(throws: RuleScenarioCoverage.Failure.notARulesDocument) {
            try RuleScenarioCoverage.gaps(rulesData: Data("[]".utf8), scenarioIDs: [])
        }
    }
}

/// workstreams.md rule 5, QA-R12, QA-R13: the executable builds live services only when the machine opted in.
@Suite struct HarnessLiveOptInTests {
    private func allows(_ arguments: [String], _ environment: [String: String]) throws -> Bool {
        HarnessEnvironment.allowsLive(options: try HarnessCommandLine.parse(arguments), environment: environment)
    }

    @Test func liveNeedsTheRunnerOptInVariable() throws {
        let optedIn = [HarnessEnvironment.liveOptInVariable: "1"]
        for command in ["run", "soak", "bench"] {
            #expect(try allows([command], optedIn), "\(command)")
            // A developer Mac: no variable, so a forgotten --dry-run still cannot post an event.
            #expect(try !allows([command], [:]), "\(command)")
            #expect(try !allows([command], [HarnessEnvironment.liveOptInVariable: "0"]), "\(command)")
            #expect(try !allows([command], [HarnessEnvironment.liveOptInVariable: "yes"]), "\(command)")
            #expect(try !allows([command], ["OTHER": "1"]), "\(command)")
        }
    }

    @Test func dryRunsCoverageAndHelpNeverGetLiveServices() throws {
        let optedIn = [HarnessEnvironment.liveOptInVariable: "1"]
        for arguments in [
            ["run", "--dry-run"], ["soak", "--dry-run"], ["bench", "--dry-run"], ["coverage"], ["help"],
        ] {
            #expect(try !allows(arguments, optedIn), "\(arguments)")
        }
    }

    @Test func optInVariableName() {
        #expect(HarnessEnvironment.liveOptInVariable == "COMPAT_HARNESS_LIVE")
    }
}

@Suite struct HarnessLiveCommandTests {
    @Test func liveCommandsRefuseToRunWithoutLiveServices() async throws {
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        for command in ["run", "soak", "bench"] {
            let (harness, console) = try harness([command], fileSystem: fileSystem)
            #expect(await harness.execute() == .incomplete, "\(command)")
            #expect(console.errors.first?.contains("use --dry-run") == true)
            #expect(console.errors.first?.contains(HarnessEnvironment.liveOptInVariable + "=1") == true)
        }
    }

    @Test func runExecutesThroughTheFakesAndWritesTheReport() async throws {
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock, axText: "đi")
        let fileSystem = try makeCheckout(scenarios: [
            "a.json": scenarioJSON(
                id: "a", target: HarnessTargets.testHostAlias,
                setup:
                    #"[{"action":"launch"},{"action":"setSecureInput","value":"off"},{"action":"focusField","value":"testhost.native.textField"}]"#
            ),
            "b.json": scenarioJSON(id: "b").replacingOccurrences(of: #""đi""#, with: #""other""#),
            "h.json": scenarioJSON(id: "h", readback: "human"),
        ])
        let (harness, console) = try harness(
            ["run", "--output", "/out", "--profile", "burst"], fileSystem: fileSystem, live: live, clock: clock)
        #expect(await harness.execute() == .failure)  // b expects other text
        #expect(console.output.contains { $0.hasPrefix("pass a") })
        // b never shows its text: it is read again for the settle time before it fails.
        #expect(console.output.contains("fail b (2.0 s): observed state differs from expect"))
        #expect(console.output.contains { $0.hasPrefix("needsHuman h") })
        #expect(console.output.last == "compat-harness run: 1 passed, 1 failed, 1 need a person")
        #expect(live.sink.records.count == 18)  // 3 scenarios x 3 keys x down/up, recorded in memory only
        let host = "org.example.product.dev.testhost"
        // The run ends by releasing TestHost's secure-input holder (no stuck secure input for the next job).
        // Every TestHost scenario starts from empty fields (prepare presses TestHost's Reset fields button).
        #expect(
            live.system.calls.all == [
                "reset fields in " + host, "launch " + host, "secure false in " + host,
                "focus testhost.native.textField in " + host, "secure false in " + host,
            ])
        // The app under test was started on factory defaults; its settings were put back after the run.
        #expect(live.control.events.all == ["launch", "quit", "launch"])
        let data = try fileSystem.readData(at: URL(fileURLWithPath: "/out/results.json"), maxBytes: 1 << 20)
        let report = try JSONDecoder().decode(ScenarioRunReport.self, from: data)
        #expect(report.passed == 1 && report.failed == 1 && report.needsHuman == 1 && report.profile == .burst)
        #expect(report.results.map(\.scenario) == ["a", "b", "h"])
        #expect(
            report.results.map(\.reason) == [
                nil, "observed state differs from expect", "needs a person: no tester attached",
            ])
    }

    /// The CI contract (`run --scenarios compat/scenarios --output DIR`) passes no `--webdriver`; a webdriver
    /// scenario still reaches the loopback chromedriver default.
    @Test func webdriverScenarioRunsWithoutTheWebdriverFlag() async throws {
        let transport = FakeTransport.browser(text: "đi")
        let live = RecordingLiveServices(clock: ManualClock(), transport: transport)
        let fileSystem = try makeCheckout(scenarios: [
            "w.json": scenarioJSON(
                id: "w", target: "com.example.Browser", readback: "webdriver",
                setup: ##"[{"action":"openURL","value":"{pages}/fields.html"},{"action":"focusField","value":"#t"}]"##)
        ])
        let (harness, console) = try harness(
            ["run", "--scenarios", "compat/scenarios", "--output", "/out"], fileSystem: fileSystem, live: live)
        #expect(await harness.execute() == .success)
        #expect(console.output.contains { $0.hasPrefix("pass w") })
        #expect(transport.urls.all.allSatisfy { $0.host == "127.0.0.1" && $0.port == 9515 })
        #expect(!transport.urls.all.isEmpty)
    }

    @Test func runReportsServiceErrors() async throws {
        let live = RecordingLiveServices(clock: ManualClock())
        let fileSystem = try makeCheckout(scenarios: ["a.json": scenarioJSON(id: "a")])
        let (harness, console) = try harness(
            ["run", "--webdriver", "com.example.Browser=http://example.com:1"], fileSystem: fileSystem, live: live)
        #expect(await harness.execute() == .failure)
        #expect(console.errors.first?.contains("nonLoopbackEndpoint") == true)
    }

    @Test func soakRunsChunksAndWritesTheSummary() async throws {
        let clock = ManualClock()
        let monitor = ScriptedSoakMonitor(footprints: [30, 30.5, 31], clock: clock, stepMicroseconds: 3_600_000_000)
        let live = RecordingLiveServices(clock: clock, axText: "unused", monitor: monitor)
        let fileSystem = try makeCheckout(scenarios: [
            "t.json": scenarioJSON(id: "t", target: HarnessTargets.testHostAlias)
        ])
        let (harness, console) = try harness(
            ["soak", "--keystrokes", "48", "--chunk", "16", "--targets", "t", "--output", "/out/soak"],
            fileSystem: fileSystem,
            live: live, clock: clock)
        #expect(await harness.execute() == .failure)  // the fake AX text never matches the corpus
        let data = try fileSystem.readData(at: URL(fileURLWithPath: "/out/soak/soak-summary.json"), maxBytes: 1 << 20)
        let summary = try JSONDecoder().decode(SoakSummary.self, from: data)
        #expect(summary.keystrokes == 48 && summary.chunks == 3 && summary.failures.count == 3)
        #expect(console.output.contains { $0.contains("48 keystrokes, 3 failed chunk(s)") })
        // Every failed chunk waits the readback settle time, so the samples are a few seconds apart from 1 h.
        let growth = try #require(summary.growthMegabytesPerHour)
        #expect(abs(growth - 0.5) < 0.002)
        #expect(console.output.contains { $0.hasPrefix(String(format: "M2.growthMBPerHour %.3f, gate 5.000", growth)) })
        #expect(fileSystem.fileExists(at: URL(fileURLWithPath: "/out/soak/soak-metrics.json")))
        #expect(live.sink.records.filter { $0.event.phase == .down }.count >= 48)
    }

    /// 13.6: one capture window per soak, not one per chunk; later chunks only bring the terminal to the front.
    @Test func soakStartsTheTerminalCaptureOnce() async throws {
        let clock = ManualClock()
        let live = RecordingLiveServices(clock: clock, monitor: ScriptedSoakMonitor(footprints: [30], clock: clock))
        let fileSystem = try makeCheckout(scenarios: [
            "term.json": scenarioJSON(
                id: "term", target: "com.example.Terminal", readback: "terminalCapture",
                setup: #"[{"action":"launch"},{"action":"wait","value":"1500"}]"#)
        ])
        let (harness, _) = try harness(
            ["soak", "--keystrokes", "48", "--chunk", "16", "--targets", "term", "--output", "/out/soak"],
            fileSystem: fileSystem, live: live, clock: clock)
        _ = await harness.execute()
        #expect(
            live.system.calls.all == [
                "capture in com.example.Terminal -> terminal-capture.txt", "launch com.example.Terminal",
                "launch com.example.Terminal",
            ])
    }

    @Test func soakWithoutAMonitorFails() async throws {
        let live = RecordingLiveServices(clock: ManualClock())
        let fileSystem = try makeCheckout(scenarios: ["t.json": scenarioJSON(id: "t")])
        let (harness, console) = try harness(
            ["soak", "--targets", "t", "--keystrokes", "16"], fileSystem: fileSystem, live: live)
        #expect(await harness.execute() == .failure)
        #expect(console.errors.first?.hasPrefix("compat-harness soak:") == true)
    }

    @Test func benchWritesMedianAndRunsAndAppliesTheGate() async throws {
        let source = ScriptedMetricSource(values: ["C1.cpuPercent": [0.1, 0.2, 0.3], "M1.footprintMB": [40, 60, 45]])
        let live = RecordingLiveServices(clock: ManualClock(), metrics: source)
        let fileSystem = try makeCheckout(scenarios: [:])
        let (harness, console) = try harness(
            ["bench", "--runs", "3", "--metrics", "C1.cpuPercent,M1.footprintMB", "--output", "/out/b.json"],
            fileSystem: fileSystem, live: live)
        #expect(await harness.execute() == .success)
        let median = try JSONDecoder().decode(
            BenchmarkDocument.self,
            from: fileSystem.readData(at: URL(fileURLWithPath: "/out/b.json"), maxBytes: 1 << 20))
        #expect(median.metrics["C1.cpuPercent"]?.value == 0.2)
        #expect(median.metrics["M1.footprintMB"]?.value == 45)
        #expect(median.runs == 3)
        #expect(fileSystem.fileExists(at: URL(fileURLWithPath: "/out/b.json.runs/run-3.json")))
        #expect(console.output.contains("M1.footprintMB 45.000, gate 50.000, no baseline: ok"))
    }

    @Test func benchOverGateFailsAndUnmeasuredIsIncomplete() async throws {
        let over = RecordingLiveServices(
            clock: ManualClock(), metrics: ScriptedMetricSource(values: ["C2.cpuPercent": [3.5]]))
        let (overHarness, overConsole) = try harness(
            ["bench", "--runs", "1", "--metrics", "C2.cpuPercent"], fileSystem: try makeCheckout(scenarios: [:]),
            live: over)
        #expect(await overHarness.execute() == .failure)  // PLT-R822: above the gate, no tolerance
        #expect(overConsole.output.contains { $0.hasSuffix("OVER GATE") })
        let partial = RecordingLiveServices(
            clock: ManualClock(), metrics: ScriptedMetricSource(values: ["C1.cpuPercent": [0.1]]))
        let (partialHarness, partialConsole) = try harness(
            ["bench", "--runs", "2", "--metrics", "C1.cpuPercent,T2.p99"], fileSystem: try makeCheckout(scenarios: [:]),
            live: partial)
        #expect(await partialHarness.execute() == .incomplete)
        #expect(partialConsole.errors.first?.hasPrefix("not measured: T2.p99") == true)
        // PLT-R821: app-histogram metrics the runner cannot read yet are skipped (warned, recorded in the note),
        // so `run-integration.sh bench` measures C1/C2/M1 today; a real measuring error stays incomplete.
        let skipping = RecordingLiveServices(
            clock: ManualClock(),
            metrics: ScriptedMetricSource(values: ["C1.cpuPercent": [0.1]], unavailable: ["T2.p99", "T5.flushes"]))
        let (skippingHarness, skippingConsole) = try harness(
            ["bench", "--runs", "2", "--metrics", "C1.cpuPercent,T2.p99,T5.flushes", "--output", "/out/s.json"],
            fileSystem: try makeCheckout(scenarios: [:]), live: skipping)
        #expect(await skippingHarness.execute() == .success)
        #expect(
            skippingConsole.errors.prefix(2) == [
                "skipped: T2.p99 (needs the app export)", "skipped: T5.flushes (needs the app export)",
            ])
        let broken = RecordingLiveServices(clock: ManualClock(), metrics: nil)
        let (brokenHarness, _) = try harness(["bench"], fileSystem: try makeCheckout(scenarios: [:]), live: broken)
        #expect(await brokenHarness.execute() == .failure)
    }
}
