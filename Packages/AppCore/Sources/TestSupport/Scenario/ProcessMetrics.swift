// SPDX-License-Identifier: LicenseRef-App-Pending
//
// C1, C2 and M1 (02-platform.md 8.1, PLT-R821) from outside the app under test: CPU time and phys_footprint deltas
// of its process (live: `proc_pid_rusage`, no root needed). One run restarts the app with its windows closed and
// shares one 10-minute window: minutes 5 to 10 are the C1 idle measurement and the footprint at minute 10 is M1;
// then C2 types 10 keys per second for 5 minutes. The sampling is a live service; the procedure is here and tested.

internal import Foundation
public import RealtimeSupport

/// One reading of the app process.
public struct ProcessSample: Sendable, Hashable {
    public var cpuNanoseconds: UInt64
    public var footprintBytes: UInt64

    public init(cpuNanoseconds: UInt64, footprintBytes: UInt64) {
        self.cpuNanoseconds = cpuNanoseconds
        self.footprintBytes = footprintBytes
    }
}

/// Live: `proc_pid_rusage` of the app under test (CompatHarness/Live).
public protocol ProcessSampling: Sendable {
    func sample() throws -> ProcessSample
}

public struct ProcessMetricSource: PlatformMetricSource {
    /// Types the C2 load: 10 keys per second for `typingSeconds` into TestHost (live closure).
    public typealias Typing = @Sendable (_ seconds: Int) async throws -> Void

    public struct Durations: Sendable, Hashable {
        /// 8.1 M1: 10 minutes after launch.
        public var settleSeconds: Int
        /// 8.1 C1: 5 minutes idle, the last part of the settle window.
        public var idleSeconds: Int
        /// 8.1 C2: 5 minutes of typing.
        public var typingSeconds: Int

        public init(settleSeconds: Int = 600, idleSeconds: Int = 300, typingSeconds: Int = 300) {
            self.settleSeconds = settleSeconds
            self.idleSeconds = min(idleSeconds, settleSeconds)
            self.typingSeconds = typingSeconds
        }
    }

    private let sampling: any ProcessSampling
    private let control: any AppUnderTestControl
    private let typing: Typing
    private let clock: any MonotonicClock
    private let sleeper: any HarnessSleeper
    private let durations: Durations

    public init(
        sampling: any ProcessSampling, control: any AppUnderTestControl, typing: @escaping Typing,
        clock: any MonotonicClock, sleeper: any HarnessSleeper, durations: Durations = Durations()
    ) {
        self.sampling = sampling
        self.control = control
        self.typing = typing
        self.clock = clock
        self.sleeper = sleeper
        self.durations = durations
    }

    public func measure(_ metric: PlatformMetric) async throws -> Double {
        guard let result = await measure([metric])[metric.name] else { throw PlatformMetricUnavailable(reason: "") }
        return try result.get()
    }

    public func measure(_ metrics: [PlatformMetric]) async -> [String: Result<Double, any Error>] {
        let names = Set(metrics.map(\.name))
        var results: [String: Result<Double, any Error>] = [:]
        if names.contains("C1.cpuPercent") || names.contains("M1.footprintMB") {
            switch await Result(catching: { try await self.restInWindow() }) {
            case .success(let (idle, footprint)):
                results["C1.cpuPercent"] = .success(idle)
                results["M1.footprintMB"] = .success(footprint)
            case .failure(let error):
                results["C1.cpuPercent"] = .failure(error)
                results["M1.footprintMB"] = .failure(error)
            }
        }
        if names.contains("C2.cpuPercent") {
            results["C2.cpuPercent"] = await Result { try await self.cpuPercent { try await typing(durations.typingSeconds) } }
        }
        for metric in metrics where results[metric.name] == nil {
            results[metric.name] = .failure(PlatformMetricUnavailable(reason: "not a process metric"))
        }
        return results.filter { names.contains($0.key) }
    }

    /// Restart, wait out the settle window measuring CPU over its last `idleSeconds`, then the footprint.
    private func restInWindow() async throws -> (Double, Double) {
        if control.isRunning() { try await control.quit() }
        try await control.launch()
        let quiet = durations.settleSeconds - durations.idleSeconds
        try await sleeper.sleep(nanoseconds: UInt64(quiet) * 1_000_000_000)
        let idle = try await cpuPercent {
            try await sleeper.sleep(nanoseconds: UInt64(durations.idleSeconds) * 1_000_000_000)
        }
        return (idle, Double(try sampling.sample().footprintBytes) / 1_048_576)
    }

    /// CPU of one core in percent while `work` runs.
    private func cpuPercent(during work: () async throws -> Void) async throws -> Double {
        let before = try sampling.sample()
        let start = clock.now().nanoseconds
        try await work()
        let after = try sampling.sample()
        let wall = Double(max(1, clock.now().nanoseconds &- start))
        return Double(after.cpuNanoseconds &- before.cpuNanoseconds) / wall * 100
    }
}
