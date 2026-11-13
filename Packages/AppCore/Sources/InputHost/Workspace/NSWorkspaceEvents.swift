// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production `WorkspaceEvents` (PLT-R333, PLT-R381): NSWorkspace notifications for activation, sleep, wake and
// Fast User Switching, distributed notifications for screen lock. Thin: the mapping is `WorkspaceEventMapping`.

import AppKit
public import Foundation

@MainActor
public final class NSWorkspaceEvents: WorkspaceEvents {
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter

    /// `NSWorkspace.shared.notificationCenter` and `DistributedNotificationCenter.default()`.
    public convenience init() {
        self.init(
            workspaceCenter: NSWorkspace.shared.notificationCenter,
            distributedCenter: DistributedNotificationCenter.default())
    }

    /// Injectable centers, so tests post to private centers and never broadcast system notifications.
    public init(workspaceCenter: NotificationCenter, distributedCenter: NotificationCenter) {
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
    }

    public func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken {
        let deliver: @MainActor @Sendable (WorkspaceEvent?) -> Void = { event in
            if let event { handler(event) }
        }
        let tokens = [
            NotificationObservationToken.observe(
                WorkspaceEventMapping.workspaceNames, on: workspaceCenter, extract: WorkspaceEventMapping.event(for:),
                deliver),
            NotificationObservationToken.observe(
                WorkspaceEventMapping.distributedNames, on: distributedCenter,
                extract: WorkspaceEventMapping.event(for:), deliver),
        ]
        return CompositeObservationToken(tokens: tokens)
    }
}

enum WorkspaceEventMapping {
    static let workspaceNames: [Notification.Name] = [
        NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    static let distributedNames = [ScreenLockNotificationName.locked, ScreenLockNotificationName.unlocked]

    @Sendable static func event(for notification: Notification) -> WorkspaceEvent? {
        switch notification.name {
        case NSWorkspace.didActivateApplicationNotification:
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            return application.map { .applicationActivated(pid: $0.processIdentifier) }
        case NSWorkspace.willSleepNotification: return .willSleep
        case NSWorkspace.didWakeNotification: return .didWake
        case NSWorkspace.sessionDidResignActiveNotification: return .sessionResignedActive
        case NSWorkspace.sessionDidBecomeActiveNotification: return .sessionBecameActive
        case ScreenLockNotificationName.locked: return .screenLocked
        case ScreenLockNotificationName.unlocked: return .screenUnlocked
        default: return nil
        }
    }
}

final class CompositeObservationToken: ObservationToken {
    private let tokens: [any ObservationToken]
    init(tokens: [any ObservationToken]) { self.tokens = tokens }
    func cancel() {
        for token in tokens { token.cancel() }
    }
}
