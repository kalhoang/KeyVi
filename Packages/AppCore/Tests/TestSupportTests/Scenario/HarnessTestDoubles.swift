// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test doubles for the compat-harness services (W2-E1): system actions, WebDriver transport, tester input,
// live-service factories, soak monitor and metric source. Nothing here posts an event, opens an app or
// touches the network.

import AppModel
import Foundation
import RealtimeSupport

@testable import TestSupport

final class FakeSystemActions: SystemActions, Sendable {
    let calls = Recorder<String>()
    func launch(_ bundle: BundleKey) async throws { calls.append("launch " + bundle.rawValue) }
    func open(_ url: String, in bundle: BundleKey) async throws {
        calls.append("open " + url + " in " + bundle.rawValue)
    }
    func seedHistory(_ url: String, in bundle: BundleKey) async throws {
        calls.append("seed " + url + " in " + bundle.rawValue)
    }
    func focusField(identifier: String, in bundle: BundleKey) async throws {
        calls.append("focus " + identifier + " in " + bundle.rawValue)
    }
    func selectInputSource(_ source: InputSourceID) async throws { calls.append("source " + source.rawValue) }
    func setSecureInput(_ enabled: Bool, in bundle: BundleKey) async throws {
        calls.append("secure \(enabled) in " + bundle.rawValue)
    }
    func startTerminalCapture(in bundle: BundleKey, script: URL, captureFile: URL) async throws {
        calls.append("capture in " + bundle.rawValue + " -> " + captureFile.lastPathComponent)
    }
    func resetTestHostFields(in bundle: BundleKey) async throws { calls.append("reset fields in " + bundle.rawValue) }
}

/// Scripted WebDriver endpoint: answers by path suffix, records requests.
final class FakeTransport: HTTPTransport, Sendable {
    struct Request: Sendable, Hashable {
        var method: String
        var path: String
        var body: String
    }

    let requests = Recorder<Request>()
    /// Full request URLs (endpoint host and port included).
    let urls = Recorder<URL>()
    private let responses: [String: (Int, String)]

    init(responses: [String: (Int, String)]) { self.responses = responses }

    /// Answers a whole session: start, navigate, find, click and a field read returning `text`.
    static func browser(text: String) -> FakeTransport {
        FakeTransport(responses: [
            "/session": (200, #"{"value":{"sessionId":"S1"}}"#), "/url": (200, #"{"value":null}"#),
            "/element": (200, #"{"value":{"element-6066-11e4-a52e-4f735466cecf":"E7"}}"#),
            "/click": (200, #"{"value":null}"#), "/execute/sync": (200, #"{"value":""# + text + #""}"#),
        ])
    }

    func send(method: String, url: URL, body: Data?) async throws -> (status: Int, body: Data) {
        urls.append(url)
        requests.append(
            Request(method: method, path: url.path, body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
        let match = responses.first { url.path.hasSuffix($0.key) }?.value ?? (404, "{}")
        return (match.0, Data(match.1.utf8))
    }
}

struct FakeLineReader: LineReader {
    var answer: String?
    let prompts = Recorder<String>()
    func readLine(prompt: String) -> String? {
        prompts.append(prompt)
        return answer
    }
}

/// Live services that record every factory call; `harnessDryRunNeverTouchesLiveServices` asserts none happen.
final class RecordingLiveServices: LiveHarnessServices, Sendable {
    let calls = Recorder<String>()
    /// The targets each `systemActions(targets:)` call received (PLT-R398C: the Secure Keyboard Entry apps).
    let systemTargets = Recorder<HarnessTargets>()
    let sink: RecordingKeyEventSink
    let system = FakeSystemActions()
    let axText: String
    let monitor: (any SoakMonitor)?
    let metrics: (any PlatformMetricSource)?
    let probe: (any ScenarioStateProbe)?
    let transport: FakeTransport
    let control: FakeAppControl
    let evidence: FakePrivacyEvidence
    let sampler: FakeConnectionSampler
    /// Factory calls (`evidence`, `sink`, `system`) that throw `TestFailure.injected`.
    let failing: Set<String>
    static let library = URL(fileURLWithPath: "/library", isDirectory: true)

    init(
        clock: ManualClock, axText: String = "", monitor: (any SoakMonitor)? = nil,
        metrics: (any PlatformMetricSource)? = nil, probe: (any ScenarioStateProbe)? = nil,
        transport: FakeTransport = FakeTransport(responses: [:]),
        evidence: FakePrivacyEvidence = FakePrivacyEvidence(files: [], log: ""),
        sampler: FakeConnectionSampler = FakeConnectionSampler(samples: []), failing: Set<String> = [],
        control: FakeAppControl = FakeAppControl()
    ) {
        self.control = control
        sink = RecordingKeyEventSink(clock: clock)
        self.axText = axText
        self.monitor = monitor
        self.metrics = metrics
        self.probe = probe
        self.transport = transport
        self.evidence = evidence
        self.sampler = sampler
        self.failing = failing
    }

    private func call(_ name: String) throws {
        calls.append(name)
        if failing.contains(name) { throw TestFailure.injected }
    }

    func libraryDirectory() -> URL {
        calls.append("library")
        return Self.library
    }

    func appControl(targets: HarnessTargets) throws -> any AppUnderTestControl {
        calls.append("control")
        return control
    }

    func privacyEvidence(targets: HarnessTargets, library: URL) throws -> any PrivacyEvidenceSource {
        try call("evidence")
        return evidence
    }

    func connectionSampler() -> any ConnectionSampler {
        calls.append("sampler")
        return sampler
    }

    func keyEventSink() throws -> any KeyEventSink {
        try call("sink")
        return sink
    }

    func systemActions(targets: HarnessTargets) throws -> any SystemActions {
        try call("system")
        systemTargets.append(targets)
        return system
    }

    func axReader() -> any AXFieldReader {
        calls.append("ax")
        return FixedAXReader(text: axText)
    }

    func httpTransport() -> any HTTPTransport {
        calls.append("http")
        return transport
    }

    func lineReader() -> (any LineReader)? {
        calls.append("lineReader")
        return nil
    }

    func stateProbe(targets: HarnessTargets) -> (any ScenarioStateProbe)? {
        calls.append("probe")
        return probe
    }

    func soakMonitor(targets: HarnessTargets) throws -> any SoakMonitor {
        calls.append("monitor")
        guard let monitor else { throw TestFailure.injected }
        return monitor
    }

    func metricSource(options: HarnessOptions, targets: HarnessTargets) throws -> any PlatformMetricSource {
        calls.append("metrics")
        guard let metrics else { throw TestFailure.injected }
        return metrics
    }
}

struct FixedAXReader: AXFieldReader {
    var text: String
    func text(identifier: String?, in bundle: BundleKey) async throws -> String { text }
}

/// Footprint samples in order (MB); repeats the last one.
final class ScriptedSoakMonitor: SoakMonitor, Sendable {
    private let values: Mutex<[Double]>
    private let held: UInt64
    private let clock: ManualClock
    private let stepMicroseconds: UInt64

    init(footprints: [Double], heldFlags: UInt64 = 0, clock: ManualClock, stepMicroseconds: UInt64 = 0) {
        values = Mutex(footprints)
        held = heldFlags
        self.clock = clock
        self.stepMicroseconds = stepMicroseconds
    }

    func footprintMegabytes() async throws -> Double {
        clock.advance(byMicroseconds: stepMicroseconds)
        return values.withLock { values in values.count > 1 ? values.removeFirst() : values[0] }
    }

    func heldModifierFlags() -> UInt64 { held }
}

struct ScriptedMetricSource: PlatformMetricSource {
    var values: [String: [Double]]
    /// Metrics this source has no way to measure yet (`PlatformMetricUnavailable`).
    var unavailable: Set<String> = []
    let calls = Recorder<String>()

    func measure(_ metric: PlatformMetric) async throws -> Double {
        calls.append(metric.name)
        if unavailable.contains(metric.name) { throw PlatformMetricUnavailable(reason: "needs the app export") }
        guard let series = values[metric.name] else { throw TestFailure.injected }
        let index = calls.all.filter { $0 == metric.name }.count - 1
        return series[min(index, series.count - 1)]
    }
}

/// Records requested sleeps without waiting.
struct RecordingSleeper: HarnessSleeper {
    let requests = Recorder<UInt64>()
    func sleep(nanoseconds: UInt64) async throws { requests.append(nanoseconds) }
}
