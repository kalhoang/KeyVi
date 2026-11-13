// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Opt-in micro-benchmarks of the tap-safe primitives (W1-A "benchmark"). Run with
// `APPCORE_BENCHMARK=1 swift test --filter HotPathBenchmarks` (add `-c release -Xswiftc -enable-testing` for
// optimised numbers). Prints nanoseconds per operation; fails only if an operation is grossly slow, so the
// budget holds on a loaded shared machine. The platform gate for the whole callback is T1 (02-platform.md 8.1).

import Foundation
import Testing

@testable import Diagnostics
@testable import RealtimeSupport

private let benchmarkEnabled = ProcessInfo.processInfo.environment["APPCORE_BENCHMARK"] == "1"

/// Mean nanoseconds per call of `operation` over `iterations` calls, measured with the production clock.
private func nanosecondsPerCall(iterations: Int = 2_000_000, _ operation: () -> Void) -> Double {
    let clock = MachClock()
    operation()
    let start = clock.now()
    var index = 0
    while index < iterations {
        operation()
        index += 1
    }
    return Double(clock.now().nanoseconds(since: start)) / Double(iterations)
}

@Suite(.enabled(if: benchmarkEnabled), .serialized) struct HotPathBenchmarks {
    /// Generous ceiling per operation (debug build, shared machine); optimised builds are far below it.
    private static let ceilingNanoseconds = 2_000.0

    @Test func tapSafePrimitives() {
        let epoch = ReaderEpoch()
        let cell = SnapshotCell([UInt16](repeating: 1, count: 128), epoch: epoch)
        let ring = SPSCRing<TapLogRecord>(capacity: 1_024)
        let record = TapLogRecord(code: .flushRequested, at: .zero)
        let histogram = Log2Histogram()
        let tapLog = TapLogRing(capacity: 1_024)
        let counter = AtomicCounter()
        let clock = MachClock()
        var sink: UInt64 = 0
        var value: UInt64 = 1
        let results: [(String, Double)] = [
            (
                "SnapshotCell.read (enter, read, exit)",
                nanosecondsPerCall {
                    epoch.enter()
                    sink &+= cell.read { UInt64($0[7]) }
                    epoch.exit()
                }
            ),
            (
                "SPSCRing.push + pop",
                nanosecondsPerCall {
                    _ = ring.push(record)
                    sink &+= ring.pop()?.a ?? 0
                }
            ),
            (
                "Log2Histogram.record",
                nanosecondsPerCall {
                    histogram.record(nanoseconds: value)
                    value = value &* 6_364_136_223_846_793_005 &+ 1
                }
            ),
            ("TapLogRing.push (full ring)", nanosecondsPerCall { tapLog.push(record) }),
            ("AtomicCounter.increment", nanosecondsPerCall { counter.increment() }),
            ("MachClock.now", nanosecondsPerCall { sink &+= clock.now().nanoseconds }),
        ]
        for (name, nanoseconds) in results {
            print("benchmark", name, String(format: "%.1f ns/op", nanoseconds))
            #expect(nanoseconds < Self.ceilingNanoseconds, "\(name) took \(nanoseconds) ns")
        }
        // Writer side, reported only: it boxes the value and may take the writer lock (never on the tap).
        let publish = nanosecondsPerCall(iterations: 200_000) { cell.publish([2]) }
        print("benchmark", "SnapshotCell.publish (writer side)", String(format: "%.1f ns/op", publish))
        #expect(sink > 0)
    }
}
