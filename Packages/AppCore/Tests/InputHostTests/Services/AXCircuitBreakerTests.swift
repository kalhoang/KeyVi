// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R384: 3 timeouts within 10 s for one pid stop AX queries to it for 60 s.

import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

/// `#expect` cannot wrap a mutating call.
private func record(_ breaker: inout AXCircuitBreaker, pid: Int32, at instant: MonotonicInstant) -> Bool {
    breaker.recordTimeout(pid: pid, at: instant)
}

@Suite("AXCircuitBreaker (PLT-R384)")
struct AXCircuitBreakerTests {
    @Test func threeTimeoutsWithinTenSecondsOpenForSixtySeconds() {
        let clock = ManualClock()
        var breaker = AXCircuitBreaker()
        #expect(!record(&breaker, pid: 7, at: clock.now()))
        clock.advance(byMicroseconds: 4_000_000)
        #expect(!record(&breaker, pid: 7, at: clock.now()))
        clock.advance(byMicroseconds: 4_000_000)
        #expect(record(&breaker, pid: 7, at: clock.now()))  // opened by this one
        #expect(breaker.isOpen(pid: 7, at: clock.now()))
        #expect(!record(&breaker, pid: 7, at: clock.now()))  // already open: no second trip
        clock.advance(byMicroseconds: 59_999_999)
        #expect(breaker.isOpen(pid: 7, at: clock.now()))
        clock.advance(byMicroseconds: 1)
        #expect(!breaker.isOpen(pid: 7, at: clock.now()))
    }

    @Test func timeoutsSpreadOverMoreThanTenSecondsDoNotOpen() {
        let clock = ManualClock()
        var breaker = AXCircuitBreaker()
        for _ in 0..<6 {
            #expect(!record(&breaker, pid: 7, at: clock.now()))
            clock.advance(byMicroseconds: 5_100_000)
        }
        #expect(!breaker.isOpen(pid: 7, at: clock.now()))
    }

    @Test func breakersArePerPid() {
        let clock = ManualClock()
        var breaker = AXCircuitBreaker(threshold: 2, window: .seconds(1), cooldown: .seconds(5))
        _ = breaker.recordTimeout(pid: 1, at: clock.now())
        _ = breaker.recordTimeout(pid: 2, at: clock.now())
        #expect(record(&breaker, pid: 1, at: clock.now()))
        #expect(breaker.isOpen(pid: 1, at: clock.now()))
        #expect(!breaker.isOpen(pid: 2, at: clock.now()))
        clock.advance(byMicroseconds: 5_000_000)
        #expect(!breaker.isOpen(pid: 1, at: clock.now()))
        #expect(!record(&breaker, pid: 1, at: clock.now()))  // counting starts again
        #expect(breaker.recentTimeouts.keys.sorted() == [1])  // stale pid 2 pruned
    }
}
