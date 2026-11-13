// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bringing the app forward for a window the user asked for (Settings, onboarding, diagnostics, alerts).

import AppKit

extension NSApplication {
    /// `activate()` (cooperative activation) from macOS 14; `activate(ignoringOtherApps:)` on macOS 12 and 13,
    /// where `activate()` does not exist (ADR 0315).
    func bringToFront() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
