// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bringing the app forward for a window the user asked for (Settings, onboarding, diagnostics, alerts). With a window
// on screen the app becomes a regular app first (PRD-R28, `WindowPresenceController`), so it is in the Dock and the
// Command+Tab switcher and its menus show once it is active; an alert alone changes nothing.

import AppKit

extension NSApplication {
    /// `activate()` (cooperative activation) from macOS 14; `activate(ignoringOtherApps:)` on macOS 12 and 13,
    /// where `activate()` does not exist (ADR 0315).
    func bringToFront() {
        (delegate as? AppMain)?.windowPresence?.willActivateForWindow()
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
