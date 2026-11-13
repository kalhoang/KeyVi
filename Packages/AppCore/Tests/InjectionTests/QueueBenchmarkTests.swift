// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Micro-benchmarks of the skeleton tap <-> worker seam (W1-D work item; T1 budget p50 15 us, p99 60 us per
// callback, 02-platform.md 8.1). Bounds are deliberately loose: debug builds on shared CI machines; the release
// gates live in the benchmark pipeline (ADR 0502). They catch order-of-magnitude regressions such as a lock or an
// allocation sneaking into the tap side.

import AppModel
import Darwin
import RealtimeSupport
import Testing

@testable import Injection

/// Timing is meaningless under a sanitizer runtime (5-15x slower), so the suite skips itself there.
private let sanitizerLoaded = ["__tsan_init", "__asan_init"].contains { (symbol: String) -> Bool in
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil  // RTLD_DEFAULT
}

@Suite(.serialized, .enabled(if: !sanitizerLoaded, "timing is not meaningful under a sanitizer"))
struct QueueBenchmarkTests {
    private static let iterations = 100_000
    /// Per operation, debug build.
    private static let bound: TimeSpan = .microseconds(5)

    /// Attempts per test: the parallel test run loads the shared machine for its first seconds, so one busy
    /// moment must not decide an order-of-magnitude check. Stops at the first attempt inside the bound.
    private static let attempts = 5

    private func measurePerOperation(_ body: () -> Void) -> TimeSpan {
        let clock = MachClock()
        let started = clock.now()
        body()
        return clock.now().duration(since: started) / Self.iterations
    }

    /// The best per-operation time of up to `attempts` fresh runs; `run` builds its own state each time.
    private func bestPerOperation(_ run: () -> TimeSpan) -> TimeSpan {
        var best: TimeSpan = .seconds(1)
        for _ in 0..<Self.attempts where best >= Self.bound { best = min(best, run()) }
        return best
    }

    /// Tap side of one held key: `inFlight`, `nextSequence`, `push`; worker side: `pop`, `finished`.
    @Test func pushPopFinishRoundTrip() {
        let record = KeyEventRecord(
            kind: .keyDown, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 40,
            unicode: .empty,
            receivedAt: .zero, isProbe: false)
        let perOperation = bestPerOperation {
            let queue = JobQueue(capacity: 512, signal: WorkerSignal(), policy: .untilPosted)
            let elapsed = measurePerOperation {
                for _ in 0..<Self.iterations {
                    _ = queue.inFlight
                    let sequence = queue.nextSequence()
                    _ = queue.push(.replay(sequence, record))
                    _ = queue.pop()
                    queue.finished(sequence, expectation: nil)
                }
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
            let elapsed = measurePerOperation {
                for index in 0..<Self.iterations {
                    let sequence = queue.nextSequence()
                    _ = queue.push(
                        .boundary(BoundaryJob(sequence: sequence, reason: .focusChanged, generation: .initial)))
                    _ = queue.pop()
                    let eventSequence = UInt32(truncatingIfNeeded: index) & EventMarker.sequenceMask
                    queue.finished(
                        sequence,
                        expectation: EchoExpectation(job: sequence, finalEventSequence: eventSequence, postedAt: now))
                    _ = tracker.settle(now: now)
                    if case .echo(let echoed) = marker.classify(marker.userData(sequence: eventSequence, probe: false))
                    {
                        tracker.observed(echoed, at: now)
                    }
                    now = now.advanced(byMicroseconds: 1)
                }
            }
            #expect(queue.inFlight == 0)
            #expect(tracker.consecutiveMisses == 0)
            return elapsed
        }
        #expect(perOperation < Self.bound)
    }
}
