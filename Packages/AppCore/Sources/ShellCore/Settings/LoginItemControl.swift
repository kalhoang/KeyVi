// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Khởi động cùng hệ thống" (D17, PLT-R205). `SMAppService` is the source of truth, so the toggle reflects the service
// status, never a stored preference. macOS 12 has no `SMAppService`: the toggle is disabled and the note tells the
// user how to add the app in System Preferences (ADR 0315).

/// What the General pane shows for the login item.
public struct LoginItemPresentation: Sendable, Hashable {
    /// The toggle is on when the item is registered, including while macOS still waits for approval.
    public var isOn: Bool
    /// False on macOS 12 (`unavailable`): the toggle is disabled and the note gives the manual steps.
    public var isAvailable: Bool
    /// Extra line under the toggle.
    public var note: SettingsText?
    /// A button next to the note that opens System Settings (System Preferences on macOS 12, see `LoginItemRowText`).
    public var offersSystemSettings: Bool

    public init(status: LoginItemStatus, failed: Bool = false) {
        let legacy = status == .unavailable
        isOn = status == .enabled || status == .requiresApproval
        isAvailable = !legacy
        if failed, !legacy {
            note = .openAtLoginFailed
            offersSystemSettings = true
            return
        }
        switch status {
        case .enabled, .notRegistered:
            note = nil
            offersSystemSettings = false
        case .requiresApproval:
            note = .openAtLoginApproval
            offersSystemSettings = true
        case .notFound:
            note = .openAtLoginNotFound
            offersSystemSettings = false
        case .unavailable:
            note = .openAtLoginManual
            offersSystemSettings = true
        }
    }
}

public enum LoginItemControl {
    /// Registers or unregisters; a thrown error leaves the toggle at the real status and explains (PRD-R43).
    public static func set(_ enabled: Bool, service: any LoginItemService) -> LoginItemPresentation {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            return LoginItemPresentation(status: service.status)
        } catch {
            return LoginItemPresentation(status: service.status, failed: true)
        }
    }
}

/// The words of the login item row: the note under the toggle and the title of the button that opens the system
/// pane (also its VoiceOver label). On macOS 12 the pane names come only from SystemPanes.json in the macOS
/// language, so the note and the button spell System Preferences the same way (PRD-R64, ADR 0315); the button's
/// VoiceOver hint (`SettingsControl.openSystemPreferences`) names no pane.
public struct LoginItemRowText: Sendable, Hashable {
    public var note: String?
    public var button: String?

    public init(localizer: Localizer, appName: String, panes: SystemPaneNames, presentation: LoginItemPresentation) {
        note = presentation.note.map { note in
            note == .openAtLoginManual
                ? localizer.format(note, appName, panes.systemSettings, panes.usersGroups, panes.loginItems)
                : localizer.format(note, appName)
        }
        guard presentation.offersSystemSettings else { return }
        button =
            presentation.isAvailable
            ? localizer.string(SettingsText.openSystemSettings)
            : localizer.format(SettingsText.openSystemPreferences, panes.systemSettings)
    }
}
