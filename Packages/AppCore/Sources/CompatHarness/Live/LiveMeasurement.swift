// SPDX-License-Identifier: GPL-3.0-or-later
//
// Resource measurement of the app under test on the self-hosted runner (PLT-R821): CPU time and
// phys_footprint from `proc_pid_rusage` (no root needed), held modifiers from the combined session state. The C1,
// C2 and M1 procedure is ProcessMetricSource (TestSupport, tested); this file only samples. Runner only.

import AppKit
import AppModel
import CoreGraphics
import Darwin
import Foundation
import RealtimeSupport
import TestSupport

enum ProcessSampler {
    static func pid(_ bundle: BundleKey) throws -> pid_t {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first else {
            throw LiveError.appNotRunning(bundle.rawValue)
        }
        return app.processIdentifier
    }

    /// `ri_user_time` and `ri_system_time` are in Mach absolute time units (VERIFY on the runner's macOS), so
    /// they are converted with the timebase like MachClock does.
    static func sample(_ bundle: BundleKey) throws -> ProcessSample {
        let process = try pid(bundle)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { throw LiveError.appNotRunning(bundle.rawValue) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessSample(
            cpuNanoseconds: ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom)),
            footprintBytes: info.ri_phys_footprint)
    }
}

struct LiveProcessSampling: ProcessSampling {
    let app: BundleKey
    func sample() throws -> ProcessSample { try ProcessSampler.sample(app) }
}

struct LiveSoakMonitor: SoakMonitor {
    let app: BundleKey

    func footprintMegabytes() async throws -> Double {
        Double(try ProcessSampler.sample(app).footprintBytes) / 1_048_576
    }

    func heldModifierFlags() -> UInt64 { CGEventSource.flagsState(.combinedSessionState).rawValue }
}

/// 8.1 C2 load: 10 keys per second of Telex words into TestHost's native text view.
struct C2Typing: Sendable {
    let targets: HarnessTargets
    let system: any SystemActions
    let sink: any KeyEventSink
    let clock: any MonotonicClock
    let seed: UInt64

    func type(seconds: Int) async throws {
        guard let testHost = targets.testHostBundleID else { throw LiveError.appNotFound(HarnessTargets.testHostAlias) }
        try await system.launch(testHost)
        try await system.resetTestHostFields(in: testHost)
        try await system.focusField(identifier: TestHostControls.typingField, in: testHost)
        var keys: [String] = []
        var generator = SeededGenerator(seed: seed)
        while keys.count < seconds * 10 {
            let word = SoakCorpus.words[Int(generator.next() % UInt64(SoakCorpus.words.count))]
            keys += word.keys.map(String.init) + ["space"]
        }
        let driver = PhysicalKeyboardDriver(sink: sink, clock: clock, seed: seed)
        try await driver.type(Array(keys.prefix(seconds * 10)), intervalRange: 100_000_000...100_000_000)
    }
}
