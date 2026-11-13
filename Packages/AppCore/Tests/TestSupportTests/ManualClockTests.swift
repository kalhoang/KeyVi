// SPDX-License-Identifier: GPL-3.0-or-later
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct ManualClockTests {
    @Test func sleepAdvancesVirtualTime() {
        let clock = ManualClock(start: MonotonicInstant(nanoseconds: 1_000))
        clock.sleep(until: MonotonicInstant(nanoseconds: 5_000))
        #expect(clock.now().nanoseconds == 5_000)
        clock.advance(byMicroseconds: 2)
        #expect(clock.now().nanoseconds == 7_000)
        clock.sleep(until: MonotonicInstant(nanoseconds: 10))
        #expect(clock.now().nanoseconds == 7_000)
    }
}
