// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Live services of `compat-harness`. Self-hosted runner only (QA-R12, QA-R13): never constructed in a dry
// run (main.swift), never exercised by tests, never run on a developer Mac (workstreams.md rule 5).

import AppModel
import Foundation
import RealtimeSupport
import TestSupport

/// stdout / stderr. `print` is allowed in this CLI target (scripts/lint-log-interpolation.sh).
struct StandardConsole: HarnessConsole {
    func emit(_ line: String) { print(line) }

    func emitError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

enum LiveError: Error, CustomStringConvertible {
    case eventCreationFailed
    case appNotFound(String)
    case appNotRunning(String)
    case elementNotFound(String)
    case axFailure(String, Int32)
    case inputSourceNotFound(String)
    case unsupported(String)
    case notAvailable(String)

    var description: String {
        switch self {
        case .eventCreationFailed: "CGEvent creation failed"
        case .appNotFound(let bundle): "no application with bundle id " + bundle
        case .appNotRunning(let bundle): "application not running: " + bundle
        case .elementNotFound(let identifier): "no accessibility element with identifier " + identifier
        case .axFailure(let call, let code): call + " failed with AXError \(code)"
        case .inputSourceNotFound(let source): "input source not enabled: " + source
        case .unsupported(let what): "not supported yet: " + what
        case .notAvailable(let what): "not measurable from the harness yet: " + what
        }
    }
}

struct LiveServices: LiveHarnessServices {
    private let clock = MachClock()

    func keyEventSink() throws -> any KeyEventSink { try CGEventKeySink() }

    func systemActions(targets: HarnessTargets) throws -> any SystemActions {
        LiveSystemActions(targets: targets, clock: clock)
    }

    func axReader() -> any AXFieldReader { LiveAXFieldReader() }

    func httpTransport() -> any HTTPTransport { URLSessionTransport() }

    func lineReader() -> (any LineReader)? { isatty(STDIN_FILENO) == 1 ? TerminalLineReader() : nil }

    /// W2-E2 adds the app-state probe (pause reason and secure-input holder from the app under test).
    func stateProbe(targets: HarnessTargets) -> (any ScenarioStateProbe)? { nil }

    func soakMonitor(targets: HarnessTargets) throws -> any SoakMonitor {
        guard let app = targets.appUnderTestBundleID else { throw LiveError.appNotFound("app under test") }
        return LiveSoakMonitor(app: app)
    }

    func metricSource(options: HarnessOptions, targets: HarnessTargets) throws -> any PlatformMetricSource {
        guard let app = targets.appUnderTestBundleID else { throw LiveError.appNotFound("app under test") }
        return LiveMetricSource(
            app: app, targets: targets, sink: try CGEventKeySink(), system: LiveSystemActions(targets: targets, clock: clock),
            clock: clock, idleSeconds: options.idleSeconds, typingSeconds: options.typingSeconds, seed: options.seed)
    }
}

struct URLSessionTransport: HTTPTransport {
    func send(method: String, url: URL, body: Data?) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

struct TerminalLineReader: LineReader {
    func readLine(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return Swift.readLine(strippingNewline: true)
    }
}
