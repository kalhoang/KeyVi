// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test doubles for the W2-E2 harness services: an in-memory app that answers the integration hooks through the
// file-drop channel, a direct hook client, app start/stop, privacy evidence, connection sampling and process
// sampling. Nothing here posts an event, opens an app, reads the real log or touches the network.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport

@testable import TestSupport

func emptyMetrics() -> MetricsSnapshot {
    MetricsSnapshot(
        callbackDuration: .empty, decideToPosted: .empty, decideToPostedWithAX: .empty, echoRoundTrip: .empty,
        heldWait: .empty, focusRefresh: .empty, flushes: 0, tapTimeouts: 0, fallbackActivations: 0, echoLosses: 0,
        watchdogTrips: 0, lostWhilePostingBroken: 0)
}

func snapshot(_ state: AppStateSnapshot.State = .ready, pid: Int32 = 100) -> AppStateSnapshot {
    AppStateSnapshot(processIdentifier: pid, state: state, mode: .vietnamese, metrics: emptyMetrics())
}

/// The app under test answering integration hooks in memory: `respond()` handles every pending request file.
final class FakeHookApp: Sendable {
    let fileSystem: any FileSystem
    let directory: URL
    let commands = Recorder<String>()
    private let current: Mutex<AppStateSnapshot>
    private let behaviour: Mutex<(answers: Bool, rejects: Set<String>, latency: LatencyProbeResult?)>

    init(fileSystem: any FileSystem, directory: URL, state: AppStateSnapshot = snapshot()) {
        self.fileSystem = fileSystem
        self.directory = directory
        current = Mutex(state)
        behaviour = Mutex((true, [], nil))
    }

    var state: AppStateSnapshot {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    func setAnswers(_ answers: Bool) { behaviour.withLock { $0.answers = answers } }
    func reject(_ command: String) { behaviour.withLock { _ = $0.rejects.insert(command) } }
    func setLatency(_ result: LatencyProbeResult) { behaviour.withLock { $0.latency = result } }

    func respond() {
        let (answers, rejects, latency) = behaviour.withLock { ($0.answers, $0.rejects, $0.latency) }
        guard answers, let files = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        for file in files where file.lastPathComponent.hasPrefix("request-") {
            let response = directory.appendingPathComponent(
                file.lastPathComponent.replacingOccurrences(of: "request-", with: "response-"))
            guard !fileSystem.fileExists(at: response),
                let data = try? fileSystem.readData(at: file, maxBytes: 1 << 20),
                let request = try? JSONDecoder().decode(AppHookRequest.self, from: data)
            else { continue }
            commands.append(request.command)
            var answer = AppHookResponse(sequence: request.sequence)
            if rejects.contains(request.command) {
                answer.ok = false
                answer.error = "unsupported"
            } else if request.command == "state" {
                answer.state = state
            } else if request.command == "latencyProbe" {
                answer.latencyProbe = latency
            }
            try? fileSystem.writeAtomically(
                try! JSONEncoder().encode(answer), to: response, permissions: .ownerOnlyFile)
        }
    }
}

/// Sleeps on the manual clock; before each sleep the fake app answers pending requests, as the real app would
/// while the harness waits.
struct RespondingSleeper: HarnessSleeper {
    let app: FakeHookApp?
    let clock: ManualClock
    let requests = Recorder<UInt64>()

    func sleep(nanoseconds: UInt64) async throws {
        requests.append(nanoseconds)
        app?.respond()
        clock.advance(byMicroseconds: nanoseconds / 1_000)
    }
}

/// Direct hook client: answers from a closure, records commands.
final class FakeHookClient: AppHookClient, Sendable {
    let commands = Recorder<String>()
    private let handler: @Sendable (AppHookCommand) throws -> AppHookResponse

    init(handler: @escaping @Sendable (AppHookCommand) throws -> AppHookResponse) { self.handler = handler }

    /// Answers `state` with `state` and everything else with ok.
    convenience init(state: AppStateSnapshot, latency: LatencyProbeResult? = nil) {
        self.init { command in
            switch command {
            case .state: AppHookResponse(sequence: 1, state: state)
            case .latencyProbe: AppHookResponse(sequence: 1, latencyProbe: latency)
            default: AppHookResponse(sequence: 1)
            }
        }
    }

    func send(_ command: AppHookCommand) async throws -> AppHookResponse {
        commands.append(command.name)
        return try handler(command)
    }
}

final class FakeAppControl: AppUnderTestControl, Sendable {
    let events = Recorder<String>()
    private let state = Mutex<(running: Bool, pid: Int32, quits: Int)>((false, 100, 0))
    /// The quit with this number (1 = first) times out and leaves the app running.
    private let failingQuit: Int?

    init(failingQuit: Int? = nil) { self.failingQuit = failingQuit }

    func setRunning(_ running: Bool) { state.withLock { $0.running = running } }
    func isRunning() -> Bool { state.withLock { $0.running } }
    func processIdentifier() -> Int32? { state.withLock { $0.running ? $0.pid : nil } }

    func quit() async throws {
        events.append("quit")
        let number = state.withLock { state -> Int in
            state.quits += 1
            return state.quits
        }
        if number == failingQuit { throw AppQuitTimeout(bundle: "org.example.product.dev", seconds: 10) }
        state.withLock { $0.running = false }
    }

    func launch() async throws {
        events.append("launch")
        state.withLock {
            $0.running = true
            $0.pid += 1
        }
    }
}

struct FakePrivacyEvidence: PrivacyEvidenceSource {
    var files: [URL]
    var log: String
    /// Asked when the files are listed; `listedWhileRunning` records the answers.
    var appRunning: @Sendable () -> Bool = { false }
    let listedWhileRunning = Recorder<Bool>()
    func appWrittenFiles() throws -> [URL] {
        listedWhileRunning.append(appRunning())
        return files
    }
    func unifiedLog() async throws -> String { log }
}

final class FakeConnectionSampler: ConnectionSampler, Sendable {
    private let samples: Mutex<[[EgressEndpoint]]>
    private let resolved: [String: Set<String>]
    let resolutions = Recorder<String>()

    /// `samples` in order; when they run out the next sample throws (the process exited).
    init(samples: [[EgressEndpoint]], addresses: [String: Set<String>] = [:]) {
        self.samples = Mutex(samples)
        resolved = addresses
    }

    func remoteEndpoints(processIdentifier: Int32) async throws -> [EgressEndpoint] {
        try samples.withLock { samples in
            guard !samples.isEmpty else { throw TestFailure.injected }
            return samples.removeFirst()
        }
    }

    func addresses(of host: String) async -> Set<String> {
        resolutions.append(host)
        return resolved[host] ?? []
    }
}

/// Process readings: each `sample()` adds `cpuStep` nanoseconds of CPU and returns `footprint`.
final class FakeProcessSampling: ProcessSampling, Sendable {
    private let cpu = Mutex<UInt64>(0)
    let cpuStep: UInt64
    let footprint: UInt64

    init(cpuStep: UInt64, footprint: UInt64) {
        self.cpuStep = cpuStep
        self.footprint = footprint
    }

    func sample() throws -> ProcessSample {
        ProcessSample(
            cpuNanoseconds: cpu.withLock {
                $0 += cpuStep
                return $0
            }, footprintBytes: footprint)
    }
}

/// Hooks whose `state` reports the app's count of published focus snapshots (T6) from a script, one answer per
/// request; the last answer repeats.
final class FocusRefreshHooks: AppHookClient, Sendable {
    private let counts: [UInt64]
    private let requests = Mutex(0)
    init(_ counts: [UInt64]) { self.counts = counts }
    var requestCount: Int { requests.withLock { $0 } }

    func send(_ command: AppHookCommand) async throws -> AppHookResponse {
        let count = requests.withLock { number -> UInt64 in
            defer { number += 1 }
            return counts[min(number, counts.count - 1)]
        }
        var metrics = emptyMetrics()
        var buckets = metrics.focusRefresh.buckets
        buckets[0] = count
        metrics.focusRefresh = HistogramSnapshot(buckets: buckets)
        let state = AppStateSnapshot(processIdentifier: 100, state: .ready, mode: .vietnamese, metrics: metrics)
        return AppHookResponse(sequence: 0, state: state)
    }
}

/// Hooks that answer the first `answered` requests with `count` and then stop answering (`AppHookError.timeout`,
/// as `FileDropHookChannel` does after its timeout when the app is relaunching or gone). Each request first moves
/// `clock` on by `latencyNanoseconds`, the time the channel spent waiting for the answer.
final class SlowHooks: AppHookClient, Sendable {
    private let base: FocusRefreshHooks
    private let answered: Int
    private let clock: ManualClock
    private let latencyNanoseconds: UInt64
    private let requests = Mutex(0)

    init(count: UInt64, answered: Int, clock: ManualClock, latencyNanoseconds: UInt64) {
        base = FocusRefreshHooks([count])
        self.answered = answered
        self.clock = clock
        self.latencyNanoseconds = latencyNanoseconds
    }

    var requestCount: Int { requests.withLock { $0 } }

    func send(_ command: AppHookCommand) async throws -> AppHookResponse {
        let number = requests.withLock { number -> Int in
            defer { number += 1 }
            return number
        }
        clock.advance(byMicroseconds: latencyNanoseconds / 1_000)
        guard number < answered else { throw AppHookError.timeout(command: "state") }
        return try await base.send(command)
    }
}
