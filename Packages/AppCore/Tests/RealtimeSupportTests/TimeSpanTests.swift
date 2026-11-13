// SPDX-License-Identifier: LicenseRef-App-Pending
//
// ADR 0315: `TimeSpan` replaces `Swift.Duration` (macOS 13). Factories, saturating arithmetic and conversions.

import Dispatch
import Testing

@testable import RealtimeSupport

@Suite struct TimeSpanTests {
    @Test func factoriesScaleToNanoseconds() {
        #expect(TimeSpan.nanoseconds(7).nanoseconds == 7)
        #expect(TimeSpan.microseconds(3).nanoseconds == 3_000)
        #expect(TimeSpan.milliseconds(150).nanoseconds == 150_000_000)
        #expect(TimeSpan.seconds(2).nanoseconds == 2_000_000_000)
        #expect(TimeSpan.seconds(-1).nanoseconds == -1_000_000_000)
        #expect(TimeSpan.seconds(0.25).nanoseconds == 250_000_000)
        #expect(TimeSpan.milliseconds(1.5).nanoseconds == 1_500_000)
        #expect(TimeSpan.zero.nanoseconds == 0)
        #expect(TimeSpan(nanoseconds: 9) == .nanoseconds(UInt8(9)))
    }

    @Test func integerLiteralsPickTheIntegerFactory() {
        let span: TimeSpan = .seconds(3)
        #expect(span.nanoseconds == 3_000_000_000)
    }

    @Test func factoriesSaturateInsteadOfTrapping() {
        #expect(TimeSpan.seconds(Int64.max).nanoseconds == .max)
        #expect(TimeSpan.seconds(Int64.min).nanoseconds == .min)
        #expect(TimeSpan.nanoseconds(UInt64.max).nanoseconds == .max)
        #expect(TimeSpan.seconds(1e30).nanoseconds == .max)
        #expect(TimeSpan.seconds(-1e30).nanoseconds == .min)
        #expect(TimeSpan.seconds(Double.nan) == .zero)
        #expect(TimeSpan.milliseconds(Double.infinity).nanoseconds == .max)
    }

    @Test func arithmeticIsSaturating() {
        let second = TimeSpan.seconds(1)
        #expect(second + .milliseconds(500) == .milliseconds(1_500))
        #expect(second - .seconds(3) == .seconds(-2))
        #expect(-second == .seconds(-1))
        #expect(second * 3 == .seconds(3))
        #expect(2 * second == .seconds(2))
        #expect(second / 4 == .milliseconds(250))
        #expect(second / TimeSpan.milliseconds(250) == 4)
        var running = TimeSpan.zero
        running += .seconds(2)
        running -= .milliseconds(500)
        #expect(running == .milliseconds(1_500))

        let maximum = TimeSpan(nanoseconds: .max)
        let minimum = TimeSpan(nanoseconds: .min)
        #expect(maximum + second == maximum)
        #expect(minimum - second == minimum)
        #expect(minimum + .seconds(-1) == minimum)
        #expect(maximum - .seconds(-1) == maximum)
        #expect(maximum * 2 == maximum)
        #expect(maximum * -2 == minimum)
        #expect(minimum / -1 == maximum)
        #expect(second / 0 == maximum)
        #expect(-second / 0 == minimum)
        #expect(TimeSpan.zero / 0 == .zero)
    }

    @Test func ordersByLength() {
        #expect(TimeSpan.milliseconds(999) < .seconds(1))
        #expect(max(TimeSpan.seconds(-3), .zero) == .zero)
        #expect([TimeSpan.seconds(2), .milliseconds(1), .zero].sorted() == [.zero, .milliseconds(1), .seconds(2)])
    }

    @Test func convertsForFoundationAndDispatch() {
        #expect(TimeSpan.milliseconds(1_500).inSeconds == 1.5)
        #expect(TimeSpan.seconds(-1).unsignedNanoseconds == 0)
        #expect(TimeSpan.microseconds(2).unsignedNanoseconds == 2_000)
        #expect(TimeSpan.milliseconds(3).dispatchInterval == .nanoseconds(3_000_000))
        #expect(TimeSpan.seconds(-3).dispatchInterval == .nanoseconds(0))
        #expect(TimeSpan.milliseconds(1_500).description == "1.5 seconds")
    }
}

@Suite struct MonotonicInstantSpanTests {
    @Test func durationSinceIsASaturatingSpan() {
        let start = MonotonicInstant(nanoseconds: 1_000)
        let later = MonotonicInstant(nanoseconds: 4_500)
        #expect(later.duration(since: start) == .nanoseconds(3_500))
        #expect(start.duration(since: later) == .zero)
    }
}
