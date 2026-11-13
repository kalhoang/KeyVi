// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded polling of the live harness: waiting for the app under test to exit after a quit request (AppConfigurator,
// PLT-R1003), reported as its own timeout error rather than an unsupported operation, and waiting for an element of a
// just-launched app. Fakes only.

import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct AppExitWaitTests {
    /// Answers `isGone` from a script, one answer per poll; the last answer repeats.
    final class ScriptedExit: Sendable {
        private let answers: [Bool]
        private let polls = Mutex(0)
        init(_ answers: [Bool]) { self.answers = answers }
        var pollCount: Int { polls.withLock { $0 } }
        func isGone() -> Bool {
            polls.withLock { count in
                defer { count += 1 }
                return answers[min(count, answers.count - 1)]
            }
        }
    }

    @Test func returnsWithoutWaitingWhenTheProcessIsAlreadyGone() async throws {
        let sleeper = RecordingSleeper()
        let exit = ScriptedExit([true])
        try await AppExitWait.wait(
            bundle: "org.example.product.dev", timeoutNanoseconds: 10_000_000_000, sleeper: sleeper,
            isGone: exit.isGone)
        #expect(sleeper.requests.all.isEmpty && exit.pollCount == 1)
    }

    @Test func pollsUntilTheProcessIsGone() async throws {
        let sleeper = RecordingSleeper()
        let exit = ScriptedExit([false, false, false, true])
        try await AppExitWait.wait(
            bundle: "org.example.product.dev", timeoutNanoseconds: 10_000_000_000, sleeper: sleeper,
            isGone: exit.isGone)
        #expect(sleeper.requests.all == Array(repeating: AppExitWait.pollNanoseconds, count: 3))
        #expect(exit.pollCount == 4)
    }

    /// The first VM run (integration-suite.md section 10.1) reported this as "not supported yet: quit of ...".
    @Test func reportsATimeoutWithTheBundleAndTheLimit() async throws {
        let sleeper = RecordingSleeper()
        let exit = ScriptedExit([false])
        let error = await #expect(throws: AppQuitTimeout.self) {
            try await AppExitWait.wait(
                bundle: "org.example.product.dev", timeoutNanoseconds: 10_000_000_000, sleeper: sleeper,
                isGone: exit.isGone)
        }
        #expect(error == AppQuitTimeout(bundle: "org.example.product.dev", seconds: 10))
        #expect(sleeper.requests.all.count == 100, "10 s in polls of 100 ms")
        let message = try #require(error?.description)
        #expect(message.contains("org.example.product.dev") && message.contains("10 s"))
        #expect(message.hasPrefix("quit timed out:") && !message.contains("not supported"))
    }

    @Test func aPartialLastPollStillEndsAtTheLimit() async throws {
        let sleeper = RecordingSleeper()
        await #expect(throws: AppQuitTimeout(bundle: "b", seconds: 0.25)) {
            try await AppExitWait.wait(
                bundle: "b", timeoutNanoseconds: 250_000_000, sleeper: sleeper, isGone: { false })
        }
        #expect(sleeper.requests.all == [100_000_000, 100_000_000, 50_000_000])
    }
}

@Suite struct HarnessPollingTests {
    @Test func returnsTheFirstValueTheAttemptProduces() async throws {
        let sleeper = RecordingSleeper()
        let attempts = Mutex(0)
        let value = try await HarnessPolling.firstValue(timeoutNanoseconds: 5_000_000_000, sleeper: sleeper) {
            attempts.withLock { count -> String? in
                count += 1
                return count == 3 ? "window" : nil
            }
        }
        #expect(value == "window" && attempts.withLock { $0 } == 3)
        #expect(sleeper.requests.all == [100_000_000, 100_000_000])
    }

    @Test func givesUpWithNilAtTheLimitAndPassesErrorsThrough() async throws {
        let sleeper = RecordingSleeper()
        let value: Int? = try await HarnessPolling.firstValue(
            timeoutNanoseconds: 300_000_000, pollNanoseconds: 200_000_000, sleeper: sleeper
        ) { nil }
        #expect(value == nil && sleeper.requests.all == [200_000_000, 100_000_000])
        await #expect(throws: TestFailure.injected) {
            _ = try await HarnessPolling.firstValue(timeoutNanoseconds: 1, sleeper: sleeper) { () throws -> Int? in
                throw TestFailure.injected
            }
        }
    }
}
