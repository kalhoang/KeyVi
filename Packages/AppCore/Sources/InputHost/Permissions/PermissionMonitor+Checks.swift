// SPDX-License-Identifier: GPL-3.0-or-later
//
// Permission health and polling cadence (PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R730, PLT-R803).

import AppModel
import RealtimeSupport

struct PermissionMonitorState: Sendable {
    var started = false
    var fastPolling = false
    var tapUnavailable = false
    var tapInstalled = false
    var last: PermissionStatus?
    var timer: (any ScheduledTimer)?
    var timerInterval: TimeSpan?
    var liveTimer: (any ScheduledTimer)?
    var fastPollingDeadline: (any ScheduledTimer)?
    /// A full check (or a live check) is queued on the runner and has not started yet: later requests join it, so a
    /// probe call that stalls never piles up checks behind it (PLT-R730).
    var fullCheckQueued = false
    var liveCheckQueued = false
    /// Completions of the requests that joined the queued full check; they get its answer, read after they asked.
    var pendingCompletions: [@Sendable (PermissionStatus) -> Void] = []
    /// Designated requirement digest of this build: read once, the signing identity cannot change at run time.
    var digest: String??
}

/// What one check read from the probe, outside the state lock.
private struct ProbeReading {
    var accessibility: Bool
    var post: Bool
    var listen: Bool
    var listenRequired: Bool
    var digest: String?
}

extension PermissionMonitor {
    func beginChecks() {
        state.withLock { $0.started = true }
        enqueueCheck()
    }

    /// Queues one full check on the runner, or joins the one already queued and not yet started; `completion` runs
    /// on the runner with the newest status after that check (see `checkNow`).
    func enqueueCheck(_ completion: (@Sendable (PermissionStatus) -> Void)? = nil) {
        let schedule = state.withLock { state -> Bool in
            if let completion { state.pendingCompletions.append(completion) }
            guard !state.fullCheckQueued else { return false }
            state.fullCheckQueued = true
            return true
        }
        guard schedule else { return }
        runner.run { [self] in
            // Taken when the check starts: a request made from now on waits for the next check, read after it.
            let completions = state.withLock { state -> [@Sendable (PermissionStatus) -> Void] in
                state.fullCheckQueued = false
                defer { state.pendingCompletions = [] }
                return state.pendingCompletions
            }
            let status = check()
            let newest = latest ?? status
            for completion in completions { completion(newest) }
        }
    }

    /// The 1 s live check, at most one queued at a time.
    private func enqueueLiveCheck() {
        let schedule = state.withLock { state -> Bool in
            guard !state.liveCheckQueued else { return false }
            state.liveCheckQueued = true
            return true
        }
        guard schedule else { return }
        runner.run { [self] in
            state.withLock { $0.liveCheckQueued = false }
            liveCheck()
        }
    }

    func endChecks() {
        let timers = state.withLock { state -> [any ScheduledTimer] in
            defer {
                state.started = false
                state.fastPolling = false
                state.timer = nil
                state.timerInterval = nil
                state.liveTimer = nil
                state.fastPollingDeadline = nil
            }
            return [state.timer, state.liveTimer, state.fastPollingDeadline].compactMap { $0 }
        }
        for timer in timers { timer.cancel() }
    }

    /// Reads the probe without the lock (PLT-R730: a stalled TCC call never holds what the main thread takes), then
    /// commits under the lock, where the delivery queue order is the commit order.
    func check() -> PermissionStatus {
        defer { delivery.drain() }
        let (tapUnavailable, cachedDigest) = state.withLock { ($0.tapUnavailable, $0.digest) }
        let reading = read(tapUnavailable: tapUnavailable, cachedDigest: cachedDigest)
        return state.withLock { state in
            if state.digest == nil { state.digest = .some(reading.digest) }
            let status = evaluate(reading)
            let changed = state.last != status
            state.last = status
            if state.started { reschedule(&state) }
            if changed { delivery.enqueue(status) }  // under the lock: the queue order is the check order
            return status
        }
    }

    func updateFastPolling(_ enabled: Bool) {
        state.withLock { state in
            guard state.fastPolling != enabled else { return }
            state.fastPolling = enabled
            state.fastPollingDeadline?.cancel()
            state.fastPollingDeadline = nil
            if enabled {
                // PLT-R711 "maximum 5 minutes" with the PLT-R803 10 % leeway: due at 270 s, fires by 300 s.
                let leeway = Self.onboardingLimit / 10
                state.fastPollingDeadline = scheduler.schedule(after: Self.onboardingLimit - leeway, leeway: leeway) {
                    [weak self] in self?.updateFastPolling(false)
                }
            }
            if state.started { reschedule(&state) }
        }
    }

    func updateTapUnavailable(_ unavailable: Bool) {
        let changed = state.withLock { state -> Bool in
            defer { state.tapUnavailable = unavailable }
            return state.tapUnavailable != unavailable
        }
        if changed { enqueueCheck() }
    }

    func updateTapInstalled(_ installed: Bool) {
        state.withLock { state in
            guard state.tapInstalled != installed else { return }
            state.tapInstalled = installed
            if state.started { reschedule(&state) }
        }
    }

    /// PLT-R721: the 1 s check asks only `AXIsProcessTrusted()` (cheap, live); a `false` runs the full check, whose
    /// status reaches the host, which removes the tap (PLT-R730). Nothing is delivered while the grant holds.
    private func liveCheck() {
        guard state.withLock({ $0.started && $0.tapInstalled }) else { return }
        guard !probe.isAccessibilityTrusted() else { return }
        _ = check()
    }

    private func read(tapUnavailable: Bool, cachedDigest: String??) -> ProbeReading {
        let accessibility = probe.isAccessibilityTrusted()
        let post = probe.canPostEvents()
        var listen = probe.canListenToEvents()
        // PLT-R702: Input Monitoring matters only when the tap failed while Accessibility is granted; only then is
        // the live check (a tap of its own, which may prompt) worth making, and it sees a grant made after launch.
        let tapNeedsListen = tapUnavailable && accessibility
        if tapNeedsListen && !listen { listen = probe.canListenToEventsNow() }
        let digest = cachedDigest ?? probe.signingIdentityDigest()
        return ProbeReading(
            accessibility: accessibility, post: post, listen: listen, listenRequired: tapNeedsListen && !listen,
            digest: digest)
    }

    /// PLT-R720: `ready` needs Accessibility and (only when the tap needs it) Input Monitoring. Posting rides on
    /// the Accessibility grant (PLT-R701); the post preflight is reported but never gates, because it keeps its
    /// launch-time answer after a live grant, and a posting path that fails anyway is caught by echo loss
    /// (PLT-R323, PLT-R730). `stale` means the Accessibility grant recorded for this exact signing identity fails
    /// now (typically after a macOS update; PLT-R740 guidance). A missing Input Monitoring consent with a working
    /// Accessibility grant is `noPermission` plus `listenEventRequired` (PLT-R702, PLT-R712), never `stale`.
    private func evaluate(_ reading: ProbeReading) -> PermissionStatus {
        let ready = reading.accessibility && !reading.listenRequired
        let identity = reading.digest.map(HostServicesHashing.stableHash52)
        let health: PermissionStatus.Health
        if ready {
            health = .ready
            if let identity, store.integer(forKey: Self.lastGrantedDigestKey) != identity {
                store.set(identity, forKey: Self.lastGrantedDigestKey)
            }
        } else if !reading.accessibility, let identity, store.integer(forKey: Self.lastGrantedDigestKey) == identity {
            health = .stale
        } else {
            health = .noPermission
        }
        return PermissionStatus(
            accessibility: reading.accessibility ? .granted : .denied, postEvent: reading.post ? .granted : .denied,
            listenEvent: reading.listen ? .granted : .denied, listenEventRequired: reading.listenRequired,
            health: health)
    }

    /// PLT-R721 cadence: 1 s while onboarding polls fast, 2 s while not ready, 30 s while ready, plus the 1 s live
    /// Accessibility check while ready with a tap installed. Leeway 10 % (PLT-R803).
    private func reschedule(_ state: inout PermissionMonitorState) {
        let ready = state.last?.health == .ready
        let interval: TimeSpan =
            state.fastPolling ? Self.onboardingInterval : (ready ? Self.readyInterval : Self.notReadyInterval)
        if state.timerInterval != interval {
            state.timer?.cancel()
            state.timer = scheduler.scheduleRepeating(every: interval, leeway: interval / 10) { [weak self] in
                self?.enqueueCheck()
            }
            state.timerInterval = interval
        }
        let wantsLive = ready && state.tapInstalled
        if wantsLive, state.liveTimer == nil {
            state.liveTimer = scheduler.scheduleRepeating(every: Self.liveInterval, leeway: Self.liveInterval / 10) {
                [weak self] in self?.enqueueLiveCheck()
            }
        } else if !wantsLive, let live = state.liveTimer {
            live.cancel()
            state.liveTimer = nil
        }
    }
}
