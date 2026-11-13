// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deferred focus work on the ax thread (PLT-R380, PLT-R391): settle re-reads after a focus notification or an
// activation, and retries of an observer the focus owner refused. Both close gaps seen in the macOS 27 VM
// (docs/runbooks/integration-suite.md section 10.5):
// - WebKit posted AXFocusedUIElementChanged for a page's textarea while the app's focused element still read nil;
//   the textarea became readable about 15 ms later and no second notification came, so the snapshot stayed on
//   "no text focus" until the PLT-R382 idle revalidation, after the first word.
// - A freshly launched app answered AXObserverAddNotification with kAXErrorCannotComplete for about 400 ms. The
//   observer was never added again, so none of that app's focus changes arrived until the next activation.
// Timers run on `Services.scheduler` (the utility queue in production, one-shot, 10 % leeway, PLT-R803) and hop to
// the ax thread through the sink. Every item carries the epoch or attempt it belongs to, so a superseded timer
// that already fired does nothing.

import RealtimeSupport

/// Work a timer hands back to the ax thread.
enum FocusDeferredWork: Sendable, Hashable {
    /// One re-read of the settle window started with `epoch`.
    case settle(epoch: UInt64)
    /// Attempt `attempt` (1 for the first retry) to observe `pid`.
    case observerRetry(pid: Int32, attempt: Int)
}

/// Timing of the deferred focus work.
enum FocusSettle {
    /// Re-reads after a focus notification or an activation, measured from it. The last one ends the window: a
    /// focus that settles later is picked up by the next notification or the next key after a pause (PLT-R382).
    static let delays: [TimeSpan] = [.milliseconds(40), .milliseconds(120), .milliseconds(400)]
    static var window: TimeSpan { delays[delays.count - 1] }
    /// Waits between observer attempts for a focus owner that refused one (about 6 s in all), each measured from
    /// the previous attempt.
    static let observerRetryDelays: [TimeSpan] = [100, 200, 400, 800, 1_600, 3_200].map { .milliseconds($0) }

    /// PLT-R803: at least 10 % of the delay.
    static func leeway(for delay: TimeSpan) -> TimeSpan {
        .nanoseconds(max(delay.nanoseconds / 10, 1_000_000))
    }
}

/// Timers of the deferred work and the host's observer, ax thread only.
struct FocusDeferredState {
    var settleEpoch: UInt64 = 0
    var settleTimers: [any ScheduledTimer] = []
    var retryTimers: [Int32: any ScheduledTimer] = [:]
    /// Told after a deferred refresh published a snapshot, so the main thread follows (the notification path has
    /// `FocusChangeSignalingAXProvider` for that).
    var publicationObserver: (@Sendable () -> Void)?
}

extension FocusCore {
    /// Starts the settle window again (a later notification replaces the earlier window).
    func scheduleSettle() {
        guard let scheduler = services.scheduler else { return }
        cancelSettle()
        deferred.settleEpoch &+= 1
        let epoch = deferred.settleEpoch
        deferred.settleTimers = FocusSettle.delays.map { delay in
            scheduler.schedule(after: delay, leeway: FocusSettle.leeway(for: delay)) { [weak sink] in
                sink?.deferredWorkDue(.settle(epoch: epoch))
            }
        }
    }

    func runDeferred(_ work: FocusDeferredWork) {
        guard running else { return }
        switch work {
        case .settle(let epoch):
            guard epoch == deferred.settleEpoch else { return }
            settleReRead()
        case .observerRetry(let pid, let attempt):
            retryObserver(pid: pid, attempt: attempt)
        }
    }

    /// Asks for another observer attempt for `pid` after the delay of `attempt`, unless one is pending, there is
    /// no scheduler or the attempts are used up.
    func scheduleObserverRetry(pid: Int32, attempt: Int) {
        guard let scheduler = services.scheduler, attempt < FocusSettle.observerRetryDelays.count,
            deferred.retryTimers[pid] == nil
        else { return }
        let delay = FocusSettle.observerRetryDelays[attempt]
        deferred.retryTimers[pid] = scheduler.schedule(after: delay, leeway: FocusSettle.leeway(for: delay)) {
            [weak sink] in
            sink?.deferredWorkDue(.observerRetry(pid: pid, attempt: attempt + 1))
        }
    }

    func cancelObserverRetry(pid: Int32) {
        deferred.retryTimers.removeValue(forKey: pid)?.cancel()
    }

    func cancelDeferredWork() {
        cancelSettle()
        for timer in deferred.retryTimers.values { timer.cancel() }
        deferred.retryTimers = [:]
    }

    /// Like the idle revalidation: a timeout teaches nothing and ends the window, so a slow app is not asked
    /// again and again (each timeout counts towards its circuit breaker, PLT-R384).
    private func settleReRead() {
        switch refresh(force: false, idle: true) {
        case .learnedNothing: cancelSettle()
        case .unchanged: break
        case .published: deferred.publicationObserver?()
        }
    }

    private func retryObserver(pid: Int32, attempt: Int) {
        deferred.retryTimers[pid] = nil
        guard observed[pid] == nil, let wanted = wantedObservation(of: pid) else { return }
        guard addObserver(pid: pid, bundle: wanted.bundle, overlay: wanted.overlay, attempt: attempt) else { return }
        // Observed at last: the owner may have moved its focus while nobody was told.
        guard pid == current?.pid, refresh(force: false) == .published else { return }
        deferred.publicationObserver?()
    }

    private func cancelSettle() {
        for timer in deferred.settleTimers { timer.cancel() }
        deferred.settleTimers = []
    }
}
