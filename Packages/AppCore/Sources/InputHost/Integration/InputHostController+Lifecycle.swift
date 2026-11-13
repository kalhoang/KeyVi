// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `InputHostController` performs the effects of the pure `HostLifecycle` (02-platform.md 2.1, PLT-R330-R333,
// PLT-R730, PLT-R731, ADR 0309, ADR 0311) with the real services: tap sessions, the worker's flush, composition
// resets, the single retry timer and health records. Workstream W2-A.

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import Injection
internal import RealtimeSupport

extension InputHostController {
    /// Feeds one input. Effects may feed more inputs (tap created or failed); they queue behind the current
    /// one, so effects always run in the order the state machine returned them.
    func feed(_ input: LifecycleInput) {
        pendingInputs.append(input)
        guard !processingInputs else { return }
        processingInputs = true
        defer { processingInputs = false }
        while !pendingInputs.isEmpty {
            let next = pendingInputs.removeFirst()
            for effect in lifecycle.handle(next, at: dependencies.clock.now()) { perform(effect) }
        }
    }

    func perform(_ effect: LifecycleEffect) {
        switch effect {
        case .publish(let phase): publishLifecycle(phase)
        case .createTap: createTap()
        case .removeTap: removeTap()
        case .disableTap: session?.thread.setEnabled(false)
        case .reenableTap: session?.reenable(at: tapClock)  // the worker stamps posts with `tapClock`
        case .requestFlush(let reason): worker.requestFlush(reason)
        case .resetComposition: channels.feedback.requestCompositionReset()
        case .scheduleRetry(let delay): scheduleRetry(after: delay)
        case .cancelRetry: cancelRetry()
        case .recordHealth(let kind): recordHealth(kind)
        case .showTapInstabilityNotice: onEvent?(.tapInstabilityNotice)
        case .publishFlags: publishLifecycle(lifecycle.phase)
        }
    }

    /// Publishes the lifecycle snapshot the tap reads at callback entry (PLT-R730: a fail-open phase stops
    /// swallowing within the same callback) and recomputes what the menu shows.
    func publishLifecycle(_ phase: LifecycleSnapshot.Phase) {
        lifecycleGeneration &+= 1
        channels.snapshots.lifecycle.publish(
            LifecycleSnapshot(
                generation: lifecycleGeneration, phase: phase, userDisabled: lifecycle.userDisabled,
                recorderActive: recorderActive, globalMode: currentFocus().mode,
                diagnosticsPassThrough: lifecycle.diagnosticsPassThrough))
        refreshState()
    }

    // MARK: Tap sessions

    /// PLT-R302: one tap at a time. The previous thread must have left its run loop (ADR 0309); its echo
    /// expectations are settled so the in-flight count is exact, and the new tap gets a fresh echo tracker.
    /// Creation happens only while permissions look granted, so posting works again by definition and the
    /// postingBroken flag is cleared before the new tap transforms (W1-F2 request, PLT-R731).
    func createTap() {
        if let retired = retiredSession {
            guard retired.thread.waitUntilExited(timeout: TapSession.previousExitTimeout) else {
                feed(.tapCreationFailed)
                return
            }
            retired.retireEchoes()
            retiredSession = nil
        }
        channels.feedback.clearPostingBroken()
        let echo = EchoTracker(queue: channels.queue, roundTrip: dependencies.metrics.echoRoundTrip)
        let context = PipelineContext(
            snapshots: channels.snapshots, queue: channels.queue, feedback: channels.feedback, echo: echo,
            marker: channels.marker, outbox: channels.outbox, metrics: dependencies.metrics,
            tapLog: dependencies.tapLog, capture: dependencies.capture, watchdog: channels.callbackWatchdog,
            counters: counters, signposts: dependencies.signposts)
        let thread = makeTapThread(context)
        let watchdog = makeWatchdog(for: thread)
        let candidate = TapSession(thread: thread, echo: echo, watchdog: watchdog)
        guard thread.start() else {
            // The tracker never reached a tap thread; its expectations are settled with the next session.
            retiredSession = candidate
            permissionMonitor?.setTapUnavailable(true)
            feed(.tapCreationFailed)
            return
        }
        session = candidate
        channels.activityRelay.connect { [weak watchdog] in watchdog?.callbackActivity() }
        watchdog.start()
        permissionMonitor?.setTapUnavailable(false)
        dependencies.logger.log(.lifecycle(.tapCreated), level: .info)
        feed(.tapCreated)
    }

    /// PLT-R730 order: the published phase already stopped swallowing; the worker replays held events (flush
    /// effect before this one); then the tap is disabled and removed. The thread is not waited for here.
    func removeTap() {
        guard let current = session else { return }
        channels.activityRelay.connect(nil)
        current.remove()
        session = nil
        retiredSession = current
        dependencies.logger.log(.lifecycle(.tapRemoved), level: .info)
    }

    private func makeWatchdog(for thread: any TapControlStarting) -> TapWatchdog {
        let hop = self.hop
        return TapWatchdog(
            tap: thread, callbacks: channels.callbackWatchdog, snapshots: channels.snapshots,
            scheduler: dependencies.scheduler, clock: tapClock,
            onCallbackReturned: { [weak self] in hop.hop { self?.feed(.callbackExited) } },
            onTrip: { [weak self] trip in hop.hop { self?.feed(.watchdogTripped(trip)) } })
    }

    // MARK: Retry timer

    /// One timer for both retry kinds (tapUnavailable backoff and postingBroken backoff); the lifecycle
    /// guarantees at most one is pending (W1-F2 request). PLT-R803: at least 10 % leeway.
    /// The timer fires on the scheduler's queue; if the retry was cancelled or rescheduled before the hop to
    /// main runs, the fire is stale and must not clear (and so cancel) the newer timer.
    func scheduleRetry(after delay: Duration) {
        cancelRetry()
        let token = retryGeneration
        let hop = self.hop
        retryTimer = dependencies.scheduler.schedule(after: delay, leeway: delay / 10) { [weak self] in
            hop.hop {
                guard let self, self.retryGeneration == token else { return }
                self.retryTimer = nil
                self.feed(.retryTimerFired)
            }
        }
    }

    func cancelRetry() {
        retryGeneration &+= 1
        retryTimer?.cancel()
        retryTimer = nil
    }

    // MARK: Health

    func recordHealth(_ code: HealthEventKindCode) {
        // PLT-R306: the soak gate (8.1 M2, "zero watchdog trips") and the issue block read this counter.
        if code == .watchdogTrip { dependencies.metrics.watchdogTrips.increment() }
        guard let kind = HealthEvent.Kind(rawValue: code.rawValue) else { return }
        var detail: HealthEvent.Detail?
        if case .failOpen(let reason) = lifecycle.phase { detail = .failOpen(reason) }
        dependencies.health.record(HealthEvent(kind: kind, at: dependencies.wallClock.now(), detail: detail))
    }

    // MARK: Session activity (PLT-R333)

    /// Sleep, screen lock and Fast User Switching each make the session inactive; it is active again only when
    /// none applies (waking while the screen is still locked stays paused).
    func setInactive(_ reason: SessionInactiveReason, _ inactive: Bool) {
        if inactive { inactiveReasons.insert(reason) } else { inactiveReasons.remove(reason) }
        feed(.sessionActive(inactiveReasons.isEmpty))
    }

    /// PLT-R721: on wake, activation and a system tap disable the permissions are checked first and fed before
    /// the input that acts on them (the `LifecycleInput.permissionsChanged` contract).
    func feedFreshPermissions() {
        guard let monitor = permissionMonitor else { return }
        let status = monitor.checkNow()
        latestPermissions = status
        feed(.permissionsChanged(status))
    }
}
