// SPDX-License-Identifier: GPL-3.0-or-later
//
// Permission health and polling cadence (PLT-R701, PLT-R702, PLT-R711, PLT-R720, PLT-R721, PLT-R803).

import AppModel
import RealtimeSupport

struct PermissionMonitorState: Sendable {
    var started = false
    var fastPolling = false
    var tapUnavailable = false
    var last: PermissionStatus?
    var timer: (any ScheduledTimer)?
    var timerInterval: TimeSpan?
    var fastPollingDeadline: (any ScheduledTimer)?
    /// Designated requirement digest of this build: read once, the signing identity cannot change at run time.
    var digest: String??
}

extension PermissionMonitor {
    func beginChecks() {
        state.withLock { $0.started = true }
        _ = check()
    }

    func endChecks() {
        let timers = state.withLock { state -> [any ScheduledTimer] in
            defer {
                state.started = false
                state.fastPolling = false
                state.timer = nil
                state.timerInterval = nil
                state.fastPollingDeadline = nil
            }
            return [state.timer, state.fastPollingDeadline].compactMap { $0 }
        }
        for timer in timers { timer.cancel() }
    }

    func check() -> PermissionStatus {
        defer { delivery.drain() }
        return state.withLock { state in
            let status = evaluate(&state)
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
        if changed { _ = check() }
    }

    /// PLT-R720: `ready` needs Accessibility, posting and (only when the tap needs it) listening. `stale` means
    /// the Accessibility grant recorded for this exact signing identity fails now (typically after a macOS
    /// update; PLT-R740 guidance). A missing Input Monitoring consent with a working Accessibility grant is
    /// `noPermission` plus `listenEventRequired` (PLT-R702, PLT-R712), never `stale`.
    private func evaluate(_ state: inout PermissionMonitorState) -> PermissionStatus {
        let accessibility = probe.isAccessibilityTrusted()
        let post = probe.canPostEvents()
        let listen = probe.canListenToEvents()
        // PLT-R702: Input Monitoring is required only when the tap fails while Accessibility is granted.
        let listenRequired = state.tapUnavailable && accessibility && !listen
        let ready = accessibility && post && !listenRequired
        let identity = digest(&state).map(HostServicesHashing.stableHash52)
        let health: PermissionStatus.Health
        if ready {
            health = .ready
            if let identity, store.integer(forKey: Self.lastGrantedDigestKey) != identity {
                store.set(identity, forKey: Self.lastGrantedDigestKey)
            }
        } else if !accessibility || !post, let identity, store.integer(forKey: Self.lastGrantedDigestKey) == identity {
            health = .stale
        } else {
            health = .noPermission
        }
        return PermissionStatus(
            accessibility: accessibility ? .granted : .denied, postEvent: post ? .granted : .denied,
            listenEvent: listen ? .granted : .denied, listenEventRequired: listenRequired, health: health)
    }

    private func digest(_ state: inout PermissionMonitorState) -> String? {
        if let cached = state.digest { return cached }
        let digest = probe.signingIdentityDigest()
        state.digest = .some(digest)
        return digest
    }

    /// PLT-R721 cadence: 1 s while onboarding polls fast, 2 s while not ready, 30 s while ready. Leeway 10 %
    /// (PLT-R803).
    private func reschedule(_ state: inout PermissionMonitorState) {
        let interval: TimeSpan =
            state.fastPolling
            ? Self.onboardingInterval : (state.last?.health == .ready ? Self.readyInterval : Self.notReadyInterval)
        guard state.timerInterval != interval else { return }
        state.timer?.cancel()
        state.timer = scheduler.scheduleRepeating(every: interval, leeway: interval / 10) { [weak self] in
            _ = self?.check()
        }
        state.timerInterval = interval
    }
}
