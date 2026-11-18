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
// - On a loaded guest (VM run of 19/11/2026) TestHost refused observers for about 5 s after its launch, and the
//   retries ended before it accepted one: the owner is now asked every 2 s after the scheduled attempts while its
//   observation is wanted, and a publication of its focus asks again once a chain is over (PLT-R380 amendment).
//   An app still half up may take every name but AXFocusedUIElementChanged (probe of the control run of 18/11):
//   such a best-effort observer is kept but does not end the chain.
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
    /// PLT-R389: re-reads after a shortcut, Escape, Return, Tab or a click, measured from the trigger. No read at the
    /// trigger itself: the tap is still holding the key, so the panel or sheet it opens cannot have the focus yet.
    /// Spotlight's panel and a save sheet take the focus within tens of milliseconds to about 200 ms of the key,
    /// and the next key typically follows 80 to 300 ms later (13.2 `normal` timing: 80 to 150 ms), so the reads are
    /// dense over the first 200 ms; 400 ms ends the window like `delays`. The first keyDown after the trigger reads
    /// once more (PLT-R389), whatever the window found.
    static let triggerDelays: [TimeSpan] = [25, 60, 100, 150, 220, 400].map { .milliseconds($0) }
    /// Waits between observer attempts for a focus owner that refused one (about 6 s in all), each measured from
    /// the previous attempt.
    static let observerRetryDelays: [TimeSpan] = [100, 200, 400, 800, 1_600, 3_200].map { .milliseconds($0) }
    /// PLT-R380 amendment of 19/11/2026: after the scheduled attempts, an app that still refuses is asked again at
    /// this pace while its observation is wanted (it owns the focus, or it is a running overlay app). 2 s is the
    /// shortest steady-state period PLT-R803 allows.
    static let observerSlowRetryDelay: TimeSpan = .seconds(2)
    /// Slow attempts of one retry chain (one minute). The chain then ends; a later publication of the app's focus
    /// while it has no observer starts a new one, so a launch that takes longer still gets its observer.
    static let observerSlowRetryLimit = 30

    /// The wait before the attempt after `attempt` was refused: the scheduled delays, then the slow pace for
    /// `observerSlowRetryLimit` more attempts; nil when the chain is over.
    static func observerRetryDelay(after attempt: Int) -> TimeSpan? {
        if attempt < observerRetryDelays.count { return observerRetryDelays[attempt] }
        guard attempt < observerRetryDelays.count + observerSlowRetryLimit else { return nil }
        return observerSlowRetryDelay
    }

    /// PLT-R803: at least 10 % of the delay.
    static func leeway(for delay: TimeSpan) -> TimeSpan {
        .nanoseconds(max(delay.nanoseconds / 10, 1_000_000))
    }
}

/// Timers of the deferred work and the host's observer, ax thread only.
struct FocusDeferredState {
    var settleEpoch: UInt64 = 0
    /// The running settle window is a PLT-R389 trigger window: its reads are moved-only reads.
    var settleIfMoved = false
    var settleTimers: [any ScheduledTimer] = []
    var retryTimers: [Int32: any ScheduledTimer] = [:]
    /// The last focus read timed out (or met an open breaker, PLT-R384).
    var lastReadTimedOut = false
    /// Told after a deferred refresh published a snapshot, so the main thread follows (the notification path has
    /// `FocusChangeSignalingAXProvider` for that).
    var publicationObserver: (@Sendable () -> Void)?
}

extension FocusCore {
    /// Opens the settle window after the read that just happened, unless that read timed out: re-reading an app
    /// that does not answer would add a breaker count per focus change (PLT-R384), and the next notification or
    /// the next key after a pause reads again anyway.
    func scheduleSettleUnlessTimedOut() {
        guard !deferred.lastReadTimedOut else { return cancelSettle() }
        scheduleSettle()
    }

    /// PLT-R389: a trigger opens the trigger settle window without reading now (`FocusSettle.triggerDelays`). Its
    /// reads are idle, moved-only reads: an unchanged focus publishes nothing and costs no attribute walk, a
    /// timeout ends the window (PLT-R384).
    func revalidateAfterTrigger() {
        guard running else { return }
        guard services.scheduler != nil else {  // nothing can defer
            refresh(force: false, idle: true, ifMoved: true)
            return
        }
        scheduleSettle(delays: FocusSettle.triggerDelays, ifMoved: true)
    }

    /// Starts the settle window again (a later notification or trigger replaces the earlier window).
    func scheduleSettle(delays: [TimeSpan] = FocusSettle.delays, ifMoved: Bool = false) {
        guard let scheduler = services.scheduler else { return }
        cancelSettle()
        deferred.settleIfMoved = ifMoved
        deferred.settleEpoch &+= 1
        let epoch = deferred.settleEpoch
        deferred.settleTimers = delays.map { delay in
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
        guard let scheduler = services.scheduler, let delay = FocusSettle.observerRetryDelay(after: attempt),
            deferred.retryTimers[pid] == nil
        else { return }
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
    /// again and again (each timeout counts towards its circuit breaker, PLT-R384). With the notification read
    /// itself timing out no window opens at all, so a focus change costs one count.
    private func settleReRead() {
        switch refresh(force: false, idle: true, ifMoved: deferred.settleIfMoved) {
        case .learnedNothing: cancelSettle()
        case .unchanged: break
        case .published: deferred.publicationObserver?()
        }
    }

    /// PLT-R380 amendment of 19/11/2026: an attempt that finds the app not wanted at the moment (another app owns
    /// the focus) skips its call and keeps the chain going through the scheduled attempts; the slow attempts after
    /// them run only while the observation is wanted. No call goes to an app whose breaker is open (PLT-R384): the
    /// attempt passes and the chain goes on. A partial observer (`ObservedApplication.partial`) keeps the chain
    /// going too.
    private func retryObserver(pid: Int32, attempt: Int) {
        deferred.retryTimers[pid] = nil
        guard !observerInPlace(pid) else { return }
        guard let wanted = wantedObservation(of: pid) else {
            noteObserverAttempt(pid: pid, attempt: attempt, result: .notWanted)
            if attempt <= FocusSettle.observerRetryDelays.count { scheduleObserverRetry(pid: pid, attempt: attempt) }
            return
        }
        guard !breaker.isOpen(pid: pid, at: services.clock.now()) else {
            noteObserverAttempt(pid: pid, attempt: attempt, result: .breakerOpen)
            return scheduleObserverRetry(pid: pid, attempt: attempt)
        }
        guard addObserver(pid: pid, bundle: wanted.bundle, overlay: wanted.overlay, attempt: attempt) else { return }
        // Observed at last: the owner may have moved its focus while nobody was told.
        guard pid == current?.pid, refresh(force: false) == .published else { return }
        deferred.publicationObserver?()
    }

    /// PLT-R380 amendment of 19/11/2026: a publication of the owner's focus while the owner has no observer (or only
    /// a partial one) and no retry is pending asks for the observer again (a new owner was already asked by
    /// `observeOwner`), so an app that refused a whole chain gets its observer once it accepts, without waiting for
    /// the next activation.
    func observeOwnerIfUnobserved(at instant: MonotonicInstant) {
        guard let pid = current?.pid, !observerInPlace(pid), deferred.retryTimers[pid] == nil,
            let wanted = wantedObservation(of: pid), !breaker.isOpen(pid: pid, at: instant)
        else { return }
        // Unlike an owner change, this install is news: the app had refused a whole chain.
        if addObserver(pid: pid, bundle: wanted.bundle, overlay: wanted.overlay, attempt: 0) {
            noteObserverAttempt(pid: pid, attempt: 0, result: .installed)
        }
    }

    private func cancelSettle() {
        for timer in deferred.settleTimers { timer.cancel() }
        deferred.settleTimers = []
    }
}
