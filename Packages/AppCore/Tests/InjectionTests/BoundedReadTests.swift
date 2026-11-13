// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R461 step 1, PLT-R462: a blocking read bounded by a deadline, one read at a time.

import Dispatch
import Foundation
import RealtimeSupport
import Testing

@testable import Injection

@Suite struct BoundedReadTests {
    @Test func returnsTheValueInTime() {
        let read = BoundedRead(label: "test.bounded-read")
        #expect(read.run(timeout: .seconds(5)) { 42 } == 42)
        #expect(!read.isBusy)
    }

    /// The caller gives up at the deadline; the overrun keeps the queue busy, so no second read runs next to it.
    @Test func anOverrunIsAbandonedAndBlocksFurtherReadsUntilItEnds() {
        let read = BoundedRead(label: "test.bounded-read")
        let release = DispatchSemaphore(value: 0)
        let clock = MachClock()
        let started = clock.now()
        let first: Int? = read.run(timeout: .milliseconds(50)) {
            release.wait()
            return 1
        }
        #expect(first == nil)
        #expect(clock.now().duration(since: started) < .seconds(2))
        #expect(read.isBusy)
        #expect(read.run(timeout: .seconds(5)) { 2 } == nil, "a second read never runs next to the first")
        release.signal()
        for _ in 0..<500 where read.isBusy { Thread.sleep(forTimeInterval: 0.01) }
        #expect(read.run(timeout: .seconds(5)) { 3 } == 3)
    }

    @Test func dispatchIntervals() {
        #expect(BoundedRead.dispatchInterval(.milliseconds(100)) == .nanoseconds(100_000_000))
        #expect(BoundedRead.dispatchInterval(.zero) == .nanoseconds(0))
        #expect(BoundedRead.dispatchInterval(.seconds(-1)) == .nanoseconds(0))
    }
}
