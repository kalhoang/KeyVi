// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R802: signposts around callback, job and AX calls in all builds; no cost when not recording.

import Testing

@testable import Diagnostics

@Suite struct SignpostsTests {
    @Test func everyIntervalHasAStaticName() {
        let names = [PlatformSignposts.Interval.tapCallback, .injectionJob, .axCall].map { $0.name.description }
        #expect(names == ["tapCallback", "injectionJob", "axCall"])
    }

    @Test func beginAndEndPairUpForEveryInterval() {
        let signposts = PlatformSignposts(subsystem: "test.signposts")
        for interval in [PlatformSignposts.Interval.tapCallback, .injectionJob, .axCall] {
            let token = signposts.begin(interval)
            signposts.end(interval, token)
        }
        // A token from a disabled log (raw 0) is ignored by `end`.
        signposts.end(.axCall, PlatformSignposts.Token(raw: 0))
    }
}
