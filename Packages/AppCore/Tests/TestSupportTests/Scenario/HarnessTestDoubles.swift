// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Test doubles for the compat-harness services (W2-E1): system actions, WebDriver transport, tester input,
// live-service factories, soak monitor and metric source. Nothing here posts an event, opens an app or
// touches the network.

import AppModel
import Foundation
import RealtimeSupport
import Synchronization
@testable import TestSupport

final class FakeSystemActions: SystemActions, Sendable {
    let calls = Recorder<String>()
    func launch(_ bundle: BundleKey) async throws { calls.append("launch " + bundle.rawValue) }
    func open(_ url: String, in bundle: BundleKey) async throws { calls.append("open " + url + " in " + bundle.rawValue) }
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
}

/// Scripted WebDriver endpoint: answers by path suffix, records requests.
final class FakeTransport: HTTPTransport, Sendable {
    struct Request: Sendable, Hashable {
        var method: String
        var path: String
        var body: String
    }

    let requests = Recorder<Request>()
    private let responses: [String: (Int, String)]

    init(responses: [String: (Int, String)]) { self.responses = responses }

    func send(method: String, url: URL, body: Data?) async throws -> (status: Int, body: Data) {
        requests.append(Request(method: method, path: url.path, body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
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
    let sink: RecordingKeyEventSink
    let system = FakeSystemActions()
    let axText: String
    let monitor: (any SoakMonitor)?
    let metrics: (any PlatformMetricSource)?
    let probe: (any ScenarioStateProbe)?

    init(
        clock: ManualClock, axText: String = "", monitor: (any SoakMonitor)? = nil,
        metrics: (any PlatformMetricSource)? = nil, probe: (any ScenarioStateProbe)? = nil
    ) {
        sink = RecordingKeyEventSink(clock: clock)
        self.axText = axText
        self.monitor = monitor
        self.metrics = metrics
        self.probe = probe
    }

    func keyEventSink() throws -> any KeyEventSink {
        calls.append("sink")
        return sink
    }

    func systemActions(targets: HarnessTargets) throws -> any SystemActions {
        calls.append("system")
        return system
    }

    func axReader() -> any AXFieldReader {
        calls.append("ax")
        return FixedAXReader(text: axText)
    }

    func httpTransport() -> any HTTPTransport {
        calls.append("http")
        return FakeTransport(responses: [:])
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
    let calls = Recorder<String>()

    func measure(_ metric: PlatformMetric) async throws -> Double {
        calls.append(metric.name)
        guard let series = values[metric.name] else { throw TestFailure.injected }
        let index = calls.all.filter { $0 == metric.name }.count - 1
        return series[min(index, series.count - 1)]
    }
}
