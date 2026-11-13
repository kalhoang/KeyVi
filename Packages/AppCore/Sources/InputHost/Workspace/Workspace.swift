// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel

public enum WorkspaceEvent: Sendable, Hashable {
    case applicationActivated(pid: Int32)  // revalidation trigger only (PLT-R381)
    case willSleep, didWake  // PLT-R333
    case sessionResignedActive, sessionBecameActive  // Fast User Switching (PLT-R333)
    case screenLocked, screenUnlocked
}

/// Production (`NSWorkspaceEvents`): `NSWorkspace.shared.notificationCenter` for
/// `didActivateApplicationNotification`, `willSleepNotification`, `didWakeNotification`,
/// `sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification`, and
/// `DistributedNotificationCenter` for the screen lock and unlock notifications (names in
/// `ReverseDNSConstants.swift`, the only file the bundle-ID lint allowlists in this module).
@MainActor
public protocol WorkspaceEvents: Sendable {
    func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken
}

/// Another Vietnamese input method running, or a built-in Vietnamese source enabled (PLT-R399, onboarding
/// screen 5). The app never terminates or modifies other apps.
public enum ConflictingInput: Sendable, Hashable {
    case runningApp(bundle: BundleKey, name: String)
    case builtInVietnameseSource(id: InputSourceID, name: String)
}

public enum ConflictDetector {
    public static func detect(
        running: [ProcessIdentity], enabledSources: [InputSourceInfo], conflictingApps: Set<BundleKey>
    ) -> [ConflictingInput] { unimplemented() }
}
