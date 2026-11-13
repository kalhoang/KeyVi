// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The tap hot path: PLT-R305 (no steady-state heap allocation outside the engine call) and the PLT-R820
// pipeline benchmark that records T1 with fakes. The benchmark writes a formatVersion 1 result
// (docs/decisions/0502-fuzz-benchmark-coverage-contracts.md) to PIPELINE_BENCH_OUTPUT when it is set; CI runs
// it in release (`swift test -c release --filter PipelineBenchmark`) and compares it with a baseline file.

import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

/// A steady typing stream: composed words, an English token restored at a comma (P0-3), backspaces, Shift,
/// Return, all as keyDown/keyUp pairs.
private enum TypingStream {
    static let words: [[UInt16]] = [
        [Key.a, Key.a, Key.s], [Key.u, Key.w], [Key.a, Key.x, Key.s], [Key.d, Key.e, Key.s],
        [Key.a, Key.s, Key.backspace],
    ]

    static func events() -> [RawKeyEvent] {
        var events: [RawKeyEvent] = []
        for (index, word) in words.enumerated() {
            if index == 1 { events.append(PipelineFixtures.keyEvent(.flagsChanged, Key.shift, flags: Flag.shift)) }
            for code in word {
                let flags: UInt64 = index == 1 && code == word.first ? Flag.shift : 0
                events.append(PipelineFixtures.keyEvent(.keyDown, code, flags: flags))
                events.append(PipelineFixtures.keyEvent(.keyUp, code, flags: flags))
                if index == 1 && code == word.first {
                    events.append(PipelineFixtures.keyEvent(.flagsChanged, Key.shift, flags: 0))
                }
            }
            let separator = index == 2 ? Key.comma : (index == 4 ? Key.returnKey : Key.space)
            events.append(PipelineFixtures.keyEvent(.keyDown, separator))
            events.append(PipelineFixtures.keyEvent(.keyUp, separator))
        }
        return events
    }
}

/// The worker's side for the hot-path tests: pops every job and finishes it at once (nothing to echo).
/// Returns how many boundary jobs it saw.
@discardableResult
private func completeJobs(_ fixture: PipelineFixture) -> Int {
    var boundaries = 0
    while let job = fixture.queue.pop() {
        let sequence = PipelineFixture.sequence(of: job)
        if case .edit = job { fixture.feedback.record(.executed, for: sequence) }
        if case .boundary = job { boundaries += 1 }
        fixture.queue.finished(sequence, expectation: nil)
    }
    return boundaries
}

@Suite("PipelineAllocationTests") struct PipelineAllocationTests {
    /// PLT-R304, PLT-R305: 10,000 steady-state events allocate and free nothing on the tap thread outside the
    /// engine call. The worker's share (popping and destroying jobs) is excluded like the engine's. The worker
    /// lags (jobs finish only every third event), so the PLT-R311 paths are measured too: holds (replay jobs),
    /// paired keyUps and boundary jobs pushed while jobs are in flight.
    @Test(.enabled(if: AllocationCounter.isAvailable, "sanitizer runtimes replace malloc and never call the hook"))
    func steadyStateAllocatesNothingOutsideTheEngine() {
        let fixture = PipelineFixture()
        let pipeline = KeyPipeline(
            context: fixture.context, factory: AllocationExcludingFactory(ScriptedEngineFactory()), clock: fixture.clock
        )
        let stream = TypingStream.events()
        var edits = 0
        var held = 0
        var pairedKeyUps = 0
        var boundaries = 0
        func step(_ index: Int) {
            let verdict = pipeline.handle(stream[index % stream.count])
            if verdict == .swallow {
                switch pipeline.lastOutcome {
                case .consumedForEdit?: edits += 1
                case .held?: held += 1
                case .consumedPairedKeyUp?: pairedKeyUps += 1
                default: break
                }
            }
            guard index % 3 == 2 else { return }
            AllocationCounter.pause()
            boundaries += completeJobs(fixture)
            AllocationCounter.resume()
        }
        for index in 0..<(stream.count * 4) { step(index) }  // warm-up: metadata, lazy globals
        // A `while` loop: in unoptimised builds `for ... in` over a range allocates on every iteration itself.
        let counts = AllocationCounter.measure {
            var index = 0
            while index < 10_000 {
                step(index)
                index += 1
            }
        }
        #expect(counts.allocations == 0, "the tap path allocated \(counts.allocations) times")
        #expect(counts.deallocations == 0, "the tap path freed \(counts.deallocations) times")
        #expect(edits > 500)  // the stream really produced edit jobs
        #expect(held > 0 && pairedKeyUps > 0 && boundaries > 0)  // and the PLT-R311 jobs behind them
    }
}

@Suite("PipelineBenchmarkTests") struct PipelineBenchmarkTests {
    private static let events = 20_000

    /// PLT-R820: T1 with the fake engine, fake poster side and real seams, plus the edit-producing subset (job
    /// construction). The assertion is a sanity bound; the gate is the CI comparison with the baseline.
    @Test func tapCallbackDurationBenchmark() throws {
        let fixture = PipelineFixture()
        let clock = MachClock()
        let pipeline = KeyPipeline(context: fixture.context, factory: ScriptedEngineFactory(), clock: clock)
        let stream = TypingStream.events()
        var all: [UInt64] = []
        var edits: [UInt64] = []
        all.reserveCapacity(Self.events)
        for index in 0..<(Self.events + 2_000) {
            let start = clock.now()
            let verdict = pipeline.handle(stream[index % stream.count])
            let duration = clock.now().nanoseconds(since: start)
            if index >= 2_000 {
                all.append(duration)
                if verdict == .swallow && pipeline.lastOutcome == .consumedForEdit { edits.append(duration) }
            }
            completeJobs(fixture)
        }
        let t1 = Percentiles(all)
        let edit = Percentiles(edits)
        #expect(t1.p50 < 1_000_000, "T1 p50 \(t1.p50) ns")
        if let path = ProcessInfo.processInfo.environment["PIPELINE_BENCH_OUTPUT"] {
            try BenchmarkResult(t1: t1, edit: edit, calibration: Self.calibrate()).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Fixed reference workload (ADR 0502 `calibration`): scales baselines across runners.
    private static func calibrate() -> UInt64 {
        let clock = MachClock()
        let start = clock.now()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2_000_000 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
        }
        let elapsed = clock.now().nanoseconds(since: start)
        return elapsed + (state & 1)  // keeps the loop observable
    }
}

private struct Percentiles {
    var p50: UInt64
    var p99: UInt64
    var p999: UInt64

    init(_ samples: [UInt64]) {
        let sorted = samples.sorted()
        func at(_ fraction: Double) -> UInt64 {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        p50 = at(0.5)
        p99 = at(0.99)
        p999 = at(0.999)
    }
}

/// formatVersion 1 (ADR 0502). Only T1.p99 has a gate (02-platform.md 8.1: p99 at most 100 us); platform
/// metrics are not calibrated.
private struct BenchmarkResult {
    var t1: Percentiles
    var edit: Percentiles
    var calibration: UInt64

    func write(to url: URL) throws {
        func metric(_ value: UInt64, budget: UInt64? = nil) -> [String: Any] {
            var entry: [String: Any] = ["value": value, "unit": "ns", "calibrated": false]
            if let budget { entry["budget"] = budget }
            return entry
        }
        let document: [String: Any] = [
            "formatVersion": 1,
            "benchmark": "pipeline",
            "calibration": ["name": "reference-loop", "nanoseconds": calibration],
            "metrics": [
                "T1.p50": metric(t1.p50), "T1.p99": metric(t1.p99, budget: 100_000), "T1.p999": metric(t1.p999),
                "T1.edit.p50": metric(edit.p50), "T1.edit.p99": metric(edit.p99),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
