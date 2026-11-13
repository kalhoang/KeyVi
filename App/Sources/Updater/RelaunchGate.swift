// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The automatic relaunch rule (PLT-R1105, PRD-R50): a downloaded update installs at quit, or earlier only when
// no key was pressed for 60 s and secure input is off, so no update ever installs in the middle of a word.
//
// The rule is evaluated once, at the moment Sparkle offers the immediate install. It never waits: in Sparkle
// 2.10.1, taking over `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` stalls the whole update
// cycle until the handler runs (no manual check, no scheduled check, no critical-update window), so holding the
// handler while the keyboard is busy would freeze the updater for the rest of the session.

/// Keyboard state the rule reads, supplied by the composition root.
struct KeyboardIdleState: Sendable, Hashable {
    /// Seconds since the last key press; `.infinity` when no key was pressed since launch.
    var secondsSinceLastKey: Double
    var secureInputOn: Bool
}

/// Decides whether the updater takes Sparkle's immediate install now, or leaves the update to install at quit.
enum RelaunchGate {
    enum Decision: Sendable, Hashable {
        /// Install and relaunch right away: the keyboard is idle and the update is an ordinary one.
        case installNow
        /// Hand the update back to Sparkle, which installs it at quit and keeps its scheduler running.
        case installOnQuit
    }

    static let requiredIdle: Duration = .seconds(60)

    /// The pure rule. A NaN or negative idle time counts as "a key was just pressed". Critical updates are always
    /// handed back, because Sparkle shows their window immediately only when it keeps the update (PRD-R54).
    static func decision(for state: KeyboardIdleState, isCritical: Bool) -> Decision {
        guard !isCritical, !state.secureInputOn else { return .installOnQuit }
        let idle = state.secondsSinceLastKey.isNaN ? 0 : max(state.secondsSinceLastKey, 0)
        return idle >= Double(requiredIdle.components.seconds) ? .installNow : .installOnQuit
    }
}
