// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R28 and PLT-R201 (amended 15/11/2026, retest of beta 2): the app starts as a menu-bar app (`LSUIElement`,
// `.accessory`) and is a regular app (Dock icon, Command+Tab, main menu) only while one of its windows is open. The
// rule and its timing are ShellCore's `AppPresenceCoordinator`; this reads `NSApp.windows` and applies the policy.
// It decides before the app activates for a window (`NSApplication.bringToFront`), when any window of the process
// becomes key or comes back from the Dock (Sparkle's update window included), and one main-queue turn after a window
// closes or resigns key. Switching the policy never activates the app: activation stays a user action. When the app
// returns to the menu bar while it is still active (the user closed its last window), it hands activation to the app
// that was in front before, so the menu bar and the keyboard do not stay with a windowless menu-bar app.

import AppKit
import ShellCore

@MainActor
final class ApplicationActivationPolicy: ActivationPolicyApplying {
    /// The last other app that became active: where activation goes back when the last window closes.
    private var previousApplication: pid_t?
    private var observer: NSObjectProtocol?

    init() {
        noteActivated(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self?.noteActivated(pid) }
        }
    }

    var presence: AppPresence { NSApp.activationPolicy() == .regular ? .regular : .menuBarOnly }

    func apply(_ presence: AppPresence) {
        NSApp.setActivationPolicy(presence == .regular ? .regular : .accessory)
    }

    func yieldActivation() {
        guard NSApp.isActive else { return }
        guard let pid = previousApplication, let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated
        else {
            NSApp.deactivate()
            return
        }
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current, options: [])
        } else {
            _ = app.activate(options: [])
        }
    }

    private func noteActivated(_ pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        previousApplication = pid
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

    /// `applicationShouldHandleReopen` (PRD-R28): restores the window the user left in the Dock itself, and returns
    /// true when the click should open Settings.
    func handleDockReopen() -> Bool {
        let windows = NSApp.windows
        switch AppPresence.dockReopenAction(windows: windows.map(UserWindowTraits.init)) {
        case .none:
            return false
        case .restoreMinimizedWindow(let index):
            windows[index].deminiaturize(nil)
            return false
        case .openSettings:
            return true
        }
    }
}
