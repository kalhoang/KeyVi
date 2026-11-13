// SPDX-License-Identifier: GPL-3.0-or-later
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

    var description: String {
        switch self {
        case .eventCreationFailed: "CGEvent creation failed"
        case .appNotFound(let bundle): "no application with bundle id " + bundle
        case .appNotRunning(let bundle): "application not running: " + bundle
        case .elementNotFound(let identifier): "no accessibility element with identifier " + identifier
        case .axFailure(let call, let code): call + " failed with AXError \(code)"
        case .inputSourceNotFound(let source): "input source not enabled: " + source
        case .unsupported(let what): "not supported yet: " + what
        }
    }
}

struct LiveServices: LiveHarnessServices {
    private let clock = MachClock()

    func keyEventSink() throws -> any KeyEventSink { try CGEventKeySink() }

    func systemActions(targets: HarnessTargets) throws -> any SystemActions {
        LiveSystemActions(targets: targets, sleeper: TaskSleeper())
    }

    func axReader() -> any AXFieldReader { LiveAXFieldReader() }

    func httpTransport() -> any HTTPTransport { URLSessionTransport() }

    func lineReader() -> (any LineReader)? { isatty(STDIN_FILENO) == 1 ? TerminalLineReader() : nil }

    /// Nil: the harness reads the pause reason and secure-input holder through the app's integration hooks.
    func stateProbe(targets: HarnessTargets) -> (any ScenarioStateProbe)? { nil }

    func soakMonitor(targets: HarnessTargets) throws -> any SoakMonitor {
        LiveSoakMonitor(app: try appUnderTest(targets))
    }

    /// C1, C2 and M1 by ProcessMetricSource over proc_pid_rusage; C2 types into TestHost.
    func metricSource(options: HarnessOptions, targets: HarnessTargets) throws -> any PlatformMetricSource {
        let app = try appUnderTest(targets)
        let typing = C2Typing(
            targets: targets, system: LiveSystemActions(targets: targets, sleeper: TaskSleeper()),
            sink: try CGEventKeySink(), clock: clock, seed: options.seed)
        return ProcessMetricSource(
            sampling: LiveProcessSampling(app: app), control: LiveAppControl(app: app, sleeper: TaskSleeper()),
            typing: { try await typing.type(seconds: $0) }, clock: clock, sleeper: TaskSleeper(),
            durations: .init(
                settleSeconds: options.settleSeconds, idleSeconds: options.idleSeconds,
                typingSeconds: options.typingSeconds))
    }

    func libraryDirectory() -> URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
    }

    func appControl(targets: HarnessTargets) throws -> any AppUnderTestControl {
        LiveAppControl(app: try appUnderTest(targets), sleeper: TaskSleeper())
    }

    func privacyEvidence(targets: HarnessTargets, library: URL) throws -> any PrivacyEvidenceSource {
        guard let folder = targets.storageFolderName else { throw LiveError.appNotFound("storage folder (brand.env)") }
        return LivePrivacyEvidence(library: library, folder: folder, app: try appUnderTest(targets))
    }

    func connectionSampler() -> any ConnectionSampler { LiveConnectionSampler() }

    private func appUnderTest(_ targets: HarnessTargets) throws -> BundleKey {
        guard let app = targets.appUnderTestBundleID else { throw LiveError.appNotFound("app under test") }
        return app
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
