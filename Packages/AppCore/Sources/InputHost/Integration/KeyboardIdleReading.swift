// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboard idleness for the updater's relaunch policy (PLT-R1105): an update installs at once only after 60 s
// without a key press and with secure input off. The App reads the session's idle time from `CGEventSource`
// and its own uptime; this pure rule turns them into "seconds since the last key press since launch".
// Workstream W2-H.

/// PLT-R1105 input of `UpdaterController`'s idle state.
public enum KeyboardIdleReading {
    /// `systemIdleSeconds`: seconds since the session's last key down. `secondsSinceLaunch`: this process's
    /// uptime. A key pressed before launch does not count, so with none since launch the answer is `.infinity`.
    /// An unusable reading (negative or not a number) counts as a key just pressed, so nothing relaunches.
    public static func secondsSinceLastKey(systemIdleSeconds: Double, secondsSinceLaunch: Double) -> Double {
        guard !systemIdleSeconds.isNaN, systemIdleSeconds >= 0 else { return 0 }
        return systemIdleSeconds >= secondsSinceLaunch ? .infinity : systemIdleSeconds
    }
}
