// SPDX-License-Identifier: GPL-3.0-or-later
//
// Micro-benchmarks of the skeleton tap <-> worker seam (W1-D work item; T1 budget p50 15 us, p99 60 us per
// callback, 02-platform.md 8.1, PLT-R820). Bounds are deliberately loose: debug builds on shared CI machines; the
// release gates live in the benchmark pipeline (ADR 0502). They catch order-of-magnitude regressions such as a lock
// or an allocation sneaking into the tap side (PLT-R304, PLT-R305).
//
// One run is many short batches and its result is the fastest batch. On a loaded machine (load average above the
// CPU count, or the whole parallel test run) the scheduler preempts the test thread or moves it to an efficiency
// core for most batches: a mean over the run, and even the median batch, then counted those pauses as cost and
// failed a 2.3 us operation against the 5 us bound. Some batch still runs undisturbed, and a cost added to every
// operation (a lock, an allocation, a system call) is in every batch, the fastest one included, so the same bound
// still exposes it.

import AppModel
import Darwin
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

/// Timing is meaningless under a sanitizer runtime (5-15x slower), so the suite skips itself there.
private let sanitizerLoaded = ["__tsan_init", "__asan_init"].contains { (symbol: String) -> Bool in
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil  // RTLD_DEFAULT
}

/// The same under Rosetta: CI runs the x86_64 slice translated on an Apple-silicon runner (PLT-R105, ADR 0315).
private let translated: Bool = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
}()

/// How a benchmark run turns batch timings into one per-operation figure.
enum BenchmarkStatistics {
    /// The smallest of `samples`; zero for no samples.
    static func fastest(_ samples: [TimeSpan]) -> TimeSpan { samples.min() ?? .zero }

    /// Per-operation time of one run: `batches` batches of `iterationsPerBatch` calls of `body`, timed one batch
    /// at a time with `clock`, and the fastest batch divided by the batch size. `body` receives the running index.
    static func fastestPerOperation(
        batches: Int, iterationsPerBatch: Int, clock: some MonotonicClock, _ body: (Int) -> Void
    ) -> TimeSpan {
        var samples: [TimeSpan] = []
        samples.reserveCapacity(batches)
        for batch in 0..<batches {
            let started = clock.now()
            for index in 0..<iterationsPerBatch { body(batch * iterationsPerBatch + index) }
            samples.append(clock.now().duration(since: started))
        }
        return fastest(samples) / iterationsPerBatch
    }
}

/// The statistic itself, without timing: disturbed batches do not move it, a cost on every operation does.
@Suite struct BenchmarkStatisticsTests {
    /// Most batches preempted or on a slower core, as measured under a load average of 30 on 10 CPUs.
    @Test func disturbedBatchesDoNotMoveTheFastest() {
        let undisturbed = [TimeSpan.microseconds(470), .microseconds(466)]
        let disturbed = (1...98).map { TimeSpan.microseconds(500 + 100 * $0) }
        #expect(BenchmarkStatistics.fastest((disturbed + undisturbed).shuffled()) == .microseconds(466))
        #expect(BenchmarkStatistics.fastest([]) == .zero)
    }

    /// A regression on the tap side (a lock, an allocation, a system call) costs every operation, so every batch.
    @Test func aCostOnEveryOperationMovesTheFastest() {
        let batches = (0..<100).map { TimeSpan.microseconds(466 + $0) }
        let regressed = batches.map { $0 + .microseconds(600) }  // 3 us more per operation in 200-call batches
        #expect(BenchmarkStatistics.fastest(regressed) == .microseconds(1_066))
        #expect(BenchmarkStatistics.fastest(regressed) / 200 > .microseconds(5))
    }

    @Test func thePerOperationFigureIsTheFastestBatchOverItsSize() {
        let clock = ManualClock()
        // Every batch but the third is "preempted" for a millisecond; each call takes 1 us.
        let perOperation = BenchmarkStatistics.fastestPerOperation(batches: 5, iterationsPerBatch: 10, clock: clock) {
            index in
            clock.advance(byMicroseconds: 1)
            if index % 10 == 0 && index / 10 != 2 { clock.advance(byMicroseconds: 1_000) }
        }
        #expect(perOperation == .microseconds(1))
    }
}

@Suite(
    .serialized,
    .enabled(if: !sanitizerLoaded && !translated, "timing is not meaningful under a sanitizer or under Rosetta"))
struct QueueBenchmarkTests {
    /// 100,000 operations per run, as one batch per 200 so a batch takes about half a millisecond, well inside a
    /// scheduler quantum.
    private static let batches = 500
    private static let iterationsPerBatch = 200
    /// Per operation, debug build.
    private static let bound: TimeSpan = .microseconds(5)

    /// Attempts per test: a whole run without one undisturbed batch must not decide an order-of-magnitude check.
    /// Stops at the first attempt inside the bound.
    private static let attempts = 5

    /// The best per-operation time of up to `attempts` fresh runs; `run` builds its own state each time.
    private func bestPerOperation(_ run: () -> TimeSpan) -> TimeSpan {
        var best: TimeSpan = .seconds(1)
        for _ in 0..<Self.attempts where best >= Self.bound { best = min(best, run()) }
        return best
    }

    private func fastestPerOperation(_ body: (Int) -> Void) -> TimeSpan {
        BenchmarkStatistics.fastestPerOperation(
            batches: Self.batches, iterationsPerBatch: Self.iterationsPerBatch, clock: MachClock(), body)
    }

    /// Tap side of one held key: `inFlight`, `nextSequence`, `push`; worker side: `pop`, `finished`.
    @Test func pushPopFinishRoundTrip() {
        let record = KeyEventRecord(
            kind: .keyDown, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 40,
            unicode: .empty,
            receivedAt: .zero, isProbe: false)
        let perOperation = bestPerOperation {
            let queue = JobQueue(capacity: 512, signal: WorkerSignal(), policy: .untilPosted)
            let elapsed = fastestPerOperation { _ in
                _ = queue.inFlight
                let sequence = queue.nextSequence()
                _ = queue.push(.replay(sequence, record))
                _ = queue.pop()
                queue.finished(sequence, expectation: nil)
            }
            #expect(queue.inFlight == 0)
            return elapsed
        }
        #expect(perOperation < Self.bound)
    }

    /// Tap side of echo bookkeeping: `settle` at callback entry plus `classify` and `observed` per echo.
    @Test func echoSettleAndClassify() {
        let marker = EventMarker(tag: 0xAB_CDEF)
        let perOperation = bestPerOperation {
            let queue = JobQueue(capacity: 512, signal: WorkerSignal())
            let tracker = EchoTracker(queue: queue)
            var now = MonotonicInstant(nanoseconds: 1_000)
            let elapsed = fastestPerOperation { index in
                let sequence = queue.nextSequence()
                _ = queue.push(.boundary(BoundaryJob(sequence: sequence, reason: .focusChanged, generation: .initial)))
                _ = queue.pop()
                let eventSequence = UInt32(truncatingIfNeeded: index) & EventMarker.sequenceMask
                queue.finished(
                    sequence,
                    expectation: EchoExpectation(job: sequence, finalEventSequence: eventSequence, postedAt: now))
                _ = tracker.settle(now: now)
                if case .echo(let echoed) = marker.classify(marker.userData(sequence: eventSequence, probe: false)) {
                    tracker.observed(echoed, at: now)
                }
                now = now.advanced(byMicroseconds: 1)
            }
            #expect(queue.inFlight == 0)
            #expect(tracker.consecutiveMisses == 0)
            return elapsed
        }
        #expect(perOperation < Self.bound)
    }
}
