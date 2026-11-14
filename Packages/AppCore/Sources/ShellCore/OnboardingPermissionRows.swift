// SPDX-License-Identifier: GPL-3.0-or-later
//
// Rows of the permission screen (PRD-R40 screen 2; Pa, 2026-11-14, feedback item 1): one row per permission the
// input host needs, named as System Settings names it (PLT-R704) with its live state, so a switch that is on in
// System Settings is never met by an unexplained "permission missing" (PLT-R701, PLT-R702).

public import InputHost

/// A permission the tap needs, as the user finds it in System Settings.
public enum NeededPermission: String, Sendable, Hashable, CaseIterable {
    case accessibility, inputMonitoring

    /// The pane its deep link opens (SystemPanes.json, PLT-R704).
    public var pane: SystemPane {
        switch self {
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        }
    }

    /// "Device Control and Data Access" on macOS 27, "Accessibility" before; "Input Monitoring". macOS language.
    public func paneName(_ panes: SystemPaneNames) -> String {
        switch self {
        case .accessibility: panes.accessibility
        case .inputMonitoring: panes.inputMonitoring
        }
    }
}

/// Whether a needed permission is granted, as far as the app can tell right now.
public struct PermissionNeed: Sendable, Hashable {
    public var permission: NeededPermission
    public var granted: Bool

    public init(permission: NeededPermission, granted: Bool) {
        self.permission = permission
        self.granted = granted
    }

    /// Accessibility always (PLT-R701). Input Monitoring only once the host knows the tap needs it (PLT-R702):
    /// missing while `listenEventRequired`, granted once that need cleared on this screen (`inputMonitoringSeen`).
    public static func needs(_ status: PermissionStatus, inputMonitoringSeen: Bool) -> [PermissionNeed] {
        var needs = [PermissionNeed(permission: .accessibility, granted: status.accessibility == .granted)]
        if status.listenEventRequired || inputMonitoringSeen {
            needs.append(PermissionNeed(permission: .inputMonitoring, granted: !status.listenEventRequired))
        }
        return needs
    }
}

/// One row of the screen: the pane name in the macOS language (PRD-R64), the state in the interface language.
public struct PermissionRowContent: Sendable, Hashable {
    public var permission: NeededPermission
    public var title: String
    public var state: String
    public var granted: Bool

    public init(permission: NeededPermission, title: String, state: String, granted: Bool) {
        self.permission = permission
        self.title = title
        self.state = state
        self.granted = granted
    }

    init(_ need: PermissionNeed, localizer: Localizer, panes: SystemPaneNames) {
        self.init(
            permission: need.permission, title: need.permission.paneName(panes),
            state: localizer.string(need.granted ? OnboardingText.permissionRowGranted : .permissionRowNeeded),
            granted: need.granted)
    }
}
