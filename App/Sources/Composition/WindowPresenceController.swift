// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R28 and PLT-R201 (amended 15/11/2026, retest of beta 2): the app starts as a menu-bar app (`LSUIElement`,
// `.accessory`) and is a regular app (Dock icon, Command+Tab, main menu) only while one of its windows is open. The
// rule and its timing are ShellCore's `AppPresenceCoordinator`; this reads `NSApp.windows` and applies the policy.
// It decides before the app activates for a window (`NSApplication.bringToFront`), when any window of the process
// becomes key or comes back from the Dock (Sparkle's update window included), and one main-queue turn after a window
// closes or resigns key. Switching the policy never activates the app: activation stays a user action.

import AppKit
import ShellCore

@MainActor
final class ApplicationActivationPolicy: ActivationPolicyApplying {
    var presence: AppPresence { NSApp.activationPolicy() == .regular ? .regular : .menuBarOnly }

    func apply(_ presence: AppPresence) {
        NSApp.setActivationPolicy(presence == .regular ? .regular : .accessory)
    }
}

extension UserWindowTraits {
    @MainActor
    init(_ window: NSWindow) {
        self.init(
            isTitled: window.styleMask.contains(.titled), isPanel: window is NSPanel, isSheet: window.isSheet,
            isNormalLevel: window.level == .normal, isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized)
    }
}

@MainActor
final class WindowPresenceController {
    private let coordinator = AppPresenceCoordinator(
        policy: ApplicationActivationPolicy(), windows: { NSApp.windows.map(UserWindowTraits.init) },
        isHidden: { NSApp.isHidden },
        nextTurn: { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } })
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        let now: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.willBecomeActiveNotification,
        ]
        let later: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification]
        for name in now {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.coordinator.update() }
                })
        }
        for name in later {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.coordinator.scheduleUpdate() }
                })
        }
    }

    /// Called by `NSApplication.bringToFront()` once the window is ordered front and before the app activates, so
    /// the menu bar shows the app's menus as soon as it is active.
    func willActivateForWindow() { coordinator.update() }

    /// `applicationShouldHandleReopen`: true when the Dock click should open Settings (no window can come back).
    func reopenOpensSettings(hasVisibleWindows: Bool) -> Bool {
        AppPresence.reopenOpensSettings(
            windows: NSApp.windows.map(UserWindowTraits.init), hasVisibleWindows: hasVisibleWindows)
    }
}
