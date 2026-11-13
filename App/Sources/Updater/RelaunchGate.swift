// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The automatic relaunch rule (PLT-R1105, PRD-R50): a downloaded update installs at quit, or earlier only after
// 60 s without a key press while secure input is off, so no update ever installs in the middle of a word.

import RealtimeSupport

/// Keyboard state the rule reads, supplied by the composition root.
struct KeyboardIdleState: Sendable, Hashable {
    /// Seconds since the last key press; `.infinity` when no key was pressed since launch.
    var secondsSinceLastKey: Double
    var secureInputOn: Bool
}

/// Holds Sparkle's immediate-install handler until the keyboard has been idle long enough. One-shot timers only,
/// at most one pending, never faster than once a second (PLT-R803).
@MainActor
final class RelaunchGate {
    enum Decision: Sendable, Hashable {
        case installNow
        case recheck(after: Duration)
    }

    nonisolated static let requiredIdle: Duration = .seconds(60)
    /// Secure input usually ends when a password field closes; checking every 30 s is cheap and soon enough.
    nonisolated static let secureInputRecheck: Duration = .seconds(30)
    nonisolated static let minimumRecheck: Duration = .seconds(1)
    nonisolated static let leeway: Duration = .seconds(1)

    private let idleState: @MainActor () -> KeyboardIdleState
    private let scheduler: any TimerScheduler
    private var pendingInstall: (() -> Void)?
    private var timer: (any ScheduledTimer)?

    /// `scheduler` must deliver on the main queue (production: `DispatchTimerScheduler(queue: .main)`).
    init(idleState: @escaping @MainActor () -> KeyboardIdleState, scheduler: any TimerScheduler) {
        self.idleState = idleState
        self.scheduler = scheduler
    }

    var isArmed: Bool { pendingInstall != nil }

    /// Takes Sparkle's `immediateInstallHandler`. A second call (Sparkle may offer the handler again) replaces it.
    func arm(_ install: @escaping () -> Void) {
        pendingInstall = install
        evaluate()
    }

    func disarm() {
        pendingInstall = nil
        cancelTimer()
    }

    /// The pure rule. A NaN idle time counts as "a key was just pressed".
    nonisolated static func decision(for state: KeyboardIdleState) -> Decision {
        if state.secureInputOn { return .recheck(after: secureInputRecheck) }
        let idle = state.secondsSinceLastKey.isNaN ? 0 : max(state.secondsSinceLastKey, 0)
        let required = Double(requiredIdle.components.seconds)
        guard idle < required else { return .installNow }
        return .recheck(after: max(.seconds(required - idle), minimumRecheck))
    }

    private func evaluate() {
        cancelTimer()
        guard let install = pendingInstall else { return }
        switch Self.decision(for: idleState()) {
        case .installNow:
            pendingInstall = nil
            install()
        case .recheck(let delay):
            timer = scheduler.schedule(after: delay, leeway: Self.leeway) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
