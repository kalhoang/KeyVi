// SPDX-License-Identifier: GPL-3.0-or-later

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
/// `ReverseDNSConstants.swift`, allowed by scripts/lint-bundle-ids.allow).
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

/// Pure: each conflicting app once (by bundle) in `running` order, then each enabled Vietnamese input source once.
public enum ConflictDetector {
    public static func detect(
        running: [ProcessIdentity], enabledSources: [InputSourceInfo], conflictingApps: Set<BundleKey>
    ) -> [ConflictingInput] {
        var seenApps = Set<BundleKey>()
        let apps = running.filter { conflictingApps.contains($0.bundle) && seenApps.insert($0.bundle).inserted }
            .map { ConflictingInput.runningApp(bundle: $0.bundle, name: $0.localizedName ?? $0.processName) }
        var seenSources = Set<InputSourceID>()
        let sources = enabledSources.filter { $0.isBuiltInVietnamese && seenSources.insert($0.id).inserted }
            .map { ConflictingInput.builtInVietnameseSource(id: $0.id, name: $0.localizedName) }
        return apps + sources
    }
}
