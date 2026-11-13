// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Everything `compat-harness` touches outside its own memory. `live` is nil in dry runs and on machines that
// must never receive synthetic input; the harness checks for it before any non-dry-run command, so a dry run
// cannot reach the code that posts events (workstreams.md rule 5).

public import AppModel
internal import Foundation
public import RealtimeSupport
internal import Synchronization

/// Text output of the harness (stdout / stderr in the executable, a buffer in tests).
public protocol HarnessConsole: Sendable {
    func emit(_ line: String)
    func emitError(_ line: String)
}

/// Factories for the runner-only services. Implemented in CompatHarness/Live.
public protocol LiveHarnessServices: Sendable {
    func keyEventSink() throws -> any KeyEventSink
    func systemActions(targets: HarnessTargets) throws -> any SystemActions
    func axReader() -> any AXFieldReader
    func httpTransport() -> any HTTPTransport
    /// `nil` when no terminal is attached (CI): `human` readbacks then report `needsHuman`.
    func lineReader() -> (any LineReader)?
    /// App-state probe for paused / holder expectations; `nil` until W2-E2 provides one.
    func stateProbe(targets: HarnessTargets) -> (any ScenarioStateProbe)?
    func soakMonitor(targets: HarnessTargets) throws -> any SoakMonitor
    func metricSource(options: HarnessOptions, targets: HarnessTargets) throws -> any PlatformMetricSource
}

public struct HarnessEnvironment: Sendable {
    public var fileSystem: any FileSystem
    public var console: any HarnessConsole
    public var clock: any MonotonicClock
    public var live: (any LiveHarnessServices)?

    public init(
        fileSystem: any FileSystem, console: any HarnessConsole, clock: any MonotonicClock,
        live: (any LiveHarnessServices)?
    ) {
        self.fileSystem = fileSystem
        self.console = console
        self.clock = clock
        self.live = live
    }
}

/// Exit statuses of `compat-harness`.
public enum HarnessExit: Int32, Sendable {
    case success = 0
    /// A scenario failed, a file is invalid, a gate failed or a rule lacks a scenario.
    case failure = 1
    case usage = 2
    /// The run could not measure or execute everything it was asked to (missing live service or metric).
    case incomplete = 3
}

/// Collects console output in memory (tests).
public final class BufferedConsole: HarnessConsole, Sendable {
    private let lines = Mutex<(out: [String], error: [String])>(([], []))

    public init() {}

    public var output: [String] { lines.withLock { $0.out } }
    public var errors: [String] { lines.withLock { $0.error } }
    public func emit(_ line: String) { lines.withLock { $0.out.append(line) } }
    public func emitError(_ line: String) { lines.withLock { $0.error.append(line) } }
}
