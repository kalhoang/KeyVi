// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R28 and PLT-R201 (amended 15/11/2026, retest of beta 2: with Settings open and covered by another app's window,
// Command+Tab could not bring it back). The app starts as a menu-bar app (`LSUIElement`, activation policy
// `.accessory`); while one of its windows is open, shown or in the Dock, it is a regular app with a Dock icon, a
// place in the Command+Tab switcher and its main menu, and when the last of them closes it is a menu-bar app again.
// The App target reads the windows and applies the policy; the rule and its timing live here, without AppKit.

/// What the App target reads from one of the app's windows on the main thread.
public struct UserWindowTraits: Sendable, Hashable {
    public var isTitled: Bool
    /// `NSPanel`: the switch and capture HUDs, alerts, open and save panels.
    public var isPanel: Bool
    public var isSheet: Bool
    /// Not floating above other apps (Settings is a normal window, PRD-R28).
    public var isNormalLevel: Bool
    public var isVisible: Bool
    public var isMiniaturized: Bool

    public init(
        isTitled: Bool, isPanel: Bool, isSheet: Bool, isNormalLevel: Bool, isVisible: Bool, isMiniaturized: Bool
    ) {
        self.isTitled = isTitled
        self.isPanel = isPanel
        self.isSheet = isSheet
        self.isNormalLevel = isNormalLevel
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }

    /// A window the user opened and can switch to: Settings, onboarding, Diagnostics, the bug report and the like.
    public var isUserWindow: Bool { isTitled && !isPanel && !isSheet && isNormalLevel }

    /// On screen or in the Dock.
    public var isOpen: Bool { isVisible || isMiniaturized }
}

public enum AppPresence: Sendable, Hashable {
    /// Menu bar only (`.accessory`): no Dock icon, not in the Command+Tab switcher.
    case menuBarOnly
    /// A regular app (`.regular`): Dock icon, Command+Tab, main menu.
    case regular

    /// Regular while at least one user window is open; panels, sheets and floating windows never count on their own.
    public static func presence(for windows: [UserWindowTraits]) -> AppPresence {
        windows.contains { $0.isUserWindow && $0.isOpen } ? .regular : .menuBarOnly
    }

    /// A click on the Dock icon with no window on screen: AppKit brings back a window the user left in the Dock;
    /// with none (the user kept the icon in the Dock), the app opens Settings, as the menu's "Cài đặt..." does.
    public static func reopenOpensSettings(windows: [UserWindowTraits], hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        return !windows.contains { $0.isUserWindow && $0.isMiniaturized }
    }
}

/// The application's activation policy, behind a protocol so the coordinator is tested without AppKit.
@MainActor
public protocol ActivationPolicyApplying: AnyObject {
    var presence: AppPresence { get }
    func apply(_ presence: AppPresence)
}

/// Keeps the activation policy in line with the open windows. `update()` decides at once (before the app activates
/// for a window it shows, when a window becomes key or comes back from the Dock); `scheduleUpdate()` decides on the
/// next main-queue turn (a window closes or resigns key), when a closed window is gone and a window opened by the same
/// action is on screen, so closing Settings while Diagnostics opens does not flash the Dock icon. Nothing changes
/// while the app is hidden (Command+H): the Dock icon and Command+Tab are how the user brings it back.
@MainActor
public final class AppPresenceCoordinator {
    private let policy: any ActivationPolicyApplying
    private let windows: @MainActor () -> [UserWindowTraits]
    private let isHidden: @MainActor () -> Bool
    private let nextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void
    private var updateScheduled = false

    public init(
        policy: any ActivationPolicyApplying, windows: @escaping @MainActor () -> [UserWindowTraits],
        isHidden: @escaping @MainActor () -> Bool,
        nextTurn: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void
    ) {
        self.policy = policy
        self.windows = windows
        self.isHidden = isHidden
        self.nextTurn = nextTurn
    }

    public func update() {
        guard !isHidden() else { return }
        let presence = AppPresence.presence(for: windows())
        guard policy.presence != presence else { return }
        policy.apply(presence)
    }

    public func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        nextTurn { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }
}
