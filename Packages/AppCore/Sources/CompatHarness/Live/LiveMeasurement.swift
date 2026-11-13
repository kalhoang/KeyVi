// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Resource measurement of the app under test on the self-hosted runner (PLT-R821): CPU time and
// phys_footprint from `proc_pid_rusage` deltas (no root needed), held modifiers from the combined session
// state. Runner only.

import AppKit
import AppModel
import CoreGraphics
import Darwin
import Foundation
import RealtimeSupport
import TestSupport

enum ProcessSampler {
    struct Sample {
        var cpuNanoseconds: UInt64
        var footprintBytes: UInt64
    }

    static func pid(_ bundle: BundleKey) throws -> pid_t {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first else {
            throw LiveError.appNotRunning(bundle.rawValue)
        }
        return app.processIdentifier
    }

    /// `ri_user_time` and `ri_system_time` are in Mach absolute time units (VERIFY on the runner's macOS), so
    /// they are converted with the timebase like MachClock does.
    static func sample(_ bundle: BundleKey) throws -> Sample {
        let process = try pid(bundle)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { throw LiveError.appNotRunning(bundle.rawValue) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time &+ info.ri_system_time
        return Sample(
            cpuNanoseconds: ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom)),
            footprintBytes: info.ri_phys_footprint)
    }
}

struct LiveSoakMonitor: SoakMonitor {
    let app: BundleKey

    func footprintMegabytes() async throws -> Double {
        Double(try ProcessSampler.sample(app).footprintBytes) / 1_048_576
    }

    func heldModifierFlags() -> UInt64 { CGEventSource.flagsState(.combinedSessionState).rawValue }
}

/// C1, C2 and M1 from outside the app. T2-T6 need the app's own histograms or the TestHost latency probe,
/// which W2-E2 adds; until then they are reported as not measurable, so `bench` exits incomplete.
struct LiveMetricSource: PlatformMetricSource {
    let app: BundleKey
    let targets: HarnessTargets
    let sink: any KeyEventSink
    let system: any SystemActions
    let clock: any MonotonicClock
    let idleSeconds: Int
    let typingSeconds: Int
    let seed: UInt64

    func measure(_ metric: PlatformMetric) async throws -> Double {
        switch metric.name {
        case "C1.cpuPercent": return try await cpuPercent { self.wait(seconds: idleSeconds) }
        case "C2.cpuPercent": return try await cpuPercent { try await self.typeForC2() }
        case "M1.footprintMB": return Double(try ProcessSampler.sample(app).footprintBytes) / 1_048_576
        default: throw LiveError.notAvailable(metric.name)
        }
    }

    private func cpuPercent(during work: () async throws -> Void) async throws -> Double {
        let before = try ProcessSampler.sample(app)
        let start = clock.now().nanoseconds
        try await work()
        let after = try ProcessSampler.sample(app)
        let wall = Double(max(1, clock.now().nanoseconds &- start))
        return Double(after.cpuNanoseconds &- before.cpuNanoseconds) / wall * 100
    }

    private func wait(seconds: Int) {
        clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds &+ UInt64(seconds) * 1_000_000_000))
    }

    /// 10 keys per second of Telex words into TestHost's native field (8.1 C2).
    private func typeForC2() async throws {
        guard let testHost = targets.testHostBundleID else { throw LiveError.appNotFound(HarnessTargets.testHostAlias) }
        try await system.launch(testHost)
        try await system.focusField(identifier: TestHostControls.typingField, in: testHost)
        var keys: [String] = []
        var generator = SeededGenerator(seed: seed)
        while keys.count < typingSeconds * 10 {
            let word = SoakCorpus.words[Int(generator.next() % UInt64(SoakCorpus.words.count))]
            keys += word.keys.map(String.init) + ["space"]
        }
        let driver = PhysicalKeyboardDriver(sink: sink, clock: clock, seed: seed)
        try await driver.type(Array(keys.prefix(typingSeconds * 10)), intervalRange: 100_000_000...100_000_000)
    }
}
