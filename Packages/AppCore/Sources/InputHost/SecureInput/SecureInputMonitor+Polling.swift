// SPDX-License-Identifier: GPL-3.0-or-later
//
// Secure Event Input polling, episodes and holder naming (PLT-R395-R398B). Utility queue in production.

import AppModel
import RealtimeSupport

struct SecureInputMonitorState: Sendable {
    var snapshot = SecureInputSnapshot.initial
    /// Generation whose episode the tap ended with key evidence (PLT-R398B).
    var evidenceGeneration: UInt64?
    var timer: (any ScheduledTimer)?
    var started = false
}

extension SecureInputMonitor {
    /// `proc_name` of the login window process (PLT-R396). A process name, not a bundle identifier.
    static let loginWindowProcessName = "loginwindow"

    func beginPolling() {
        let first = state.withLock { state -> Bool in
            defer { state.started = true }
            return !state.started
        }
        guard first else { return }
        _ = poll()
        let timer = scheduler.scheduleRepeating(every: Self.pollInterval, leeway: Self.pollLeeway) { [weak self] in
            _ = self?.poll()
        }
        let stale = state.withLock { state -> (any ScheduledTimer)? in
            guard state.started else { return timer }
            state.timer = timer
            return nil
        }
        stale?.cancel()
    }

    func endPolling() {
        let timer = state.withLock { state -> (any ScheduledTimer)? in
            defer {
                state.timer = nil
                state.started = false
            }
            return state.timer
        }
        timer?.cancel()
    }

    /// One poll. The generation changes on every OS transition, and also when the OS flag is still on after
    /// the tap ended the episode with key evidence: on -> off -> key -> on inside one interval pauses again.
    func poll() -> SecureInputSnapshot {
        defer { delivery.drain() }
        return state.withLock { state in
            let enabled = probe.isSecureEventInputEnabled()
            var generation = state.snapshot.generation
            if enabled != state.snapshot.enabled || (enabled && state.evidenceGeneration == generation) {
                generation &+= 1
                state.evidenceGeneration = nil
            }
            let next = SecureInputSnapshot(
                generation: generation, enabled: enabled, holder: enabled ? likelyHolder() : nil)
            if next != state.snapshot {
                state.snapshot = next
                delivery.enqueue(next)  // under the lock: the queue order is the poll order
            }
            return next
        }
    }

    func recordKeyEvidence(generation: UInt64) {
        state.withLock { state in
            guard state.snapshot.enabled, state.snapshot.generation == generation else { return }
            state.evidenceGeneration = generation
        }
    }

    /// PLT-R396: the "likely holder", which may be stale. `loginwindow` and exited processes get lock/unlock
    /// advice from their kind; applications get the data-driven hint key (PLT-R397, PLT-R398C).
    private func likelyHolder() -> SecureInputHolder? {
        guard let pid = probe.secureInputHolderPID(), pid > 0 else { return nil }
        guard processes.isAlive(pid) else {
            return SecureInputHolder(pid: pid, kind: .exitedProcess, bundle: nil, displayName: nil, hintKey: nil)
        }
        guard let identity = processes.identity(of: pid) else {
            return SecureInputHolder(pid: pid, kind: .process, bundle: nil, displayName: nil, hintKey: nil)
        }
        if identity.processName == Self.loginWindowProcessName {
            return SecureInputHolder(
                pid: pid, kind: .loginWindow, bundle: identity.bundle, displayName: identity.localizedName,
                hintKey: nil)
        }
        if identity.bundle.isExecutableHash {
            return SecureInputHolder(
                pid: pid, kind: .process, bundle: identity.bundle,
                displayName: identity.localizedName ?? identity.processName, hintKey: nil)
        }
        return SecureInputHolder(
            pid: pid, kind: .application, bundle: identity.bundle, displayName: identity.localizedName,
            hintKey: hintKey(identity.bundle))
    }
}
