// SPDX-License-Identifier: GPL-3.0-or-later
//
// One tap: the tap thread with its `KeyPipeline`, its watchdog and the echo tracker it settles jobs with
// (PLT-R302, PLT-R306, PLT-R323, ADR 0309, ADR 0311). The lifecycle owner creates a fresh session for every
// `.createTap` and never two at once. Workstream W2-A.

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import Injection
internal import RealtimeSupport

/// The production pipeline: the real engine and the uptime clock (the same base the callback stamps with).
typealias ProductionPipeline = KeyPipeline<VietnameseCompositionEngineFactory, MachClock>

/// Creates the tap thread for a pipeline context. Production: `TapThread` over the dependencies' factory.
typealias TapThreadMaker = @Sendable (PipelineContext) -> any TapControlStarting

/// `TapThread` as the session needs it: start once, then control from any thread.
protocol TapControlStarting: TapControl {
    func start() -> Bool
    func waitUntilExited(timeout: TimeSpan) -> Bool
}

extension TapThread: TapControlStarting {}

final class TapSession: Sendable {
    /// How long `.createTap` waits for the previous tap thread to leave its run loop (ADR 0309). A stopped
    /// thread exits within one run-loop turn; a stuck one never does, and then no second tap is created.
    static let previousExitTimeout: TimeSpan = .seconds(1)
    /// The same wait for a thread whose creation failed or timed out (PLT-R332, amended 15/11/2026). One that
    /// returned nil exits at once; one still inside a creation that hangs in the system is not waited for again on
    /// the main thread, and no second creation starts while it hangs (the next retry tries again).
    static let abandonedExitTimeout: TimeSpan = .milliseconds(100)

    let thread: any TapControlStarting
    let echo: EchoTracker
    let watchdog: TapWatchdog

    init(thread: any TapControlStarting, echo: EchoTracker, watchdog: TapWatchdog) {
        self.thread = thread
        self.echo = echo
        self.watchdog = watchdog
    }

    /// PLT-R730 removal: the watchdog stops first so it never reports on a tap that is going away.
    func remove() {
        watchdog.stop()
        thread.stop()
    }

    /// PLT-R330 step 1, PLT-R306 recovery (ADR 0309): the same tap is enabled again. Everything posted until the
    /// tap is back in the event route bypassed it and never echoes, so those expectations are forgiven
    /// (`EchoTracker.forgiveLostEchoes`) instead of counting as misses that would fail open with
    /// `postingBroken` (PLT-R323). Forgiven before enabling, so no callback after the enable can count them, and
    /// again after it, for anything posted in between.
    func reenable(at clock: any MonotonicClock) {
        echo.forgiveLostEchoes(postedAtOrBefore: clock.now())
        thread.setEnabled(true)
        echo.forgiveLostEchoes(postedAtOrBefore: clock.now())
    }

    /// Settles every expectation this session's tracker still holds (and every one waiting in the queue) as
    /// timed out, so the job queue's in-flight count is exact before the next session takes over. Only after
    /// the tap thread exited: `EchoTracker` is tap-thread state and the thread exit orders the accesses.
    /// The next session gets a fresh tracker, whose miss counter starts at zero, so the misses that broke
    /// posting cannot break the recreated tap again (W1-F2 request, PLT-R731).
    func retireEchoes() {
        _ = echo.settle(now: MonotonicInstant(nanoseconds: .max))
    }
}

extension TapSession {
    /// The production thread maker: one `TapThread` whose handler factory builds the pipeline on the tap thread.
    static func productionThreadMaker(factory: any EventTapFactory, creationTimeout: TimeSpan? = nil) -> TapThreadMaker
    {
        { context in
            TapThread(factory: factory, creationTimeout: creationTimeout) {
                ProductionPipeline(context: context, factory: VietnameseCompositionEngineFactory(), clock: MachClock())
            }
        }
    }
}
