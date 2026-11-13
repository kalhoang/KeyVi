// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded polling of the live harness (CompatHarness/Live): waiting for the app under test to exit after a normal
// quit request (AppConfigurator: the app flushes its settings on quit, PLT-R1003), and for an accessibility element
// of an app that was just launched. The live control asks the process whether it still exists on every poll: a
// cached `NSRunningApplication` only refreshes `isTerminated` when the harness's main run loop turns, so polling
// that flag reported a quit of 0.2 s as a 10 s timeout (integration-suite.md section 10).

/// The app under test still ran when the quit wait ended. Its own error, so a slow quit is never reported as an
/// unsupported operation.
public struct AppQuitTimeout: Error, Sendable, Hashable, CustomStringConvertible {
    public var bundle: String
    public var seconds: Double

    public init(bundle: String, seconds: Double) {
        self.bundle = bundle
        self.seconds = seconds
    }

    public var description: String {
        "quit timed out: " + bundle + " was still running " + Self.format(seconds)
            + " s after the quit request (look for a modal panel or a settings flush that blocks its quit)"
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

public enum HarnessPolling {
    public static let pollNanoseconds: UInt64 = 100_000_000

    /// Calls `attempt` until it returns a value: first at once, then after every poll. Nil when it still returned
    /// nil once `timeoutNanoseconds` passed (the last poll is shortened to end exactly at the limit).
    public static func firstValue<Value>(
        timeoutNanoseconds: UInt64, pollNanoseconds: UInt64 = HarnessPolling.pollNanoseconds,
        sleeper: any HarnessSleeper, _ attempt: () throws -> Value?
    ) async throws -> Value? {
        var waited: UInt64 = 0
        while true {
            if let value = try attempt() { return value }
            guard waited < timeoutNanoseconds else { return nil }
            let step = min(pollNanoseconds, timeoutNanoseconds - waited)
            try await sleeper.sleep(nanoseconds: step)
            waited += step
        }
    }
}

public enum AppExitWait {
    public static let pollNanoseconds = HarnessPolling.pollNanoseconds

    /// Returns once `isGone` answers true; throws `AppQuitTimeout` when it still answers false after
    /// `timeoutNanoseconds`. `isGone` is asked first without waiting, then after every poll.
    public static func wait(
        bundle: String, timeoutNanoseconds: UInt64, sleeper: any HarnessSleeper, isGone: @Sendable () -> Bool
    ) async throws {
        let gone = try await HarnessPolling.firstValue(timeoutNanoseconds: timeoutNanoseconds, sleeper: sleeper) {
            isGone() ? true : nil
        }
        guard gone != nil else {
            throw AppQuitTimeout(bundle: bundle, seconds: Double(timeoutNanoseconds) / 1_000_000_000)
        }
    }
}
