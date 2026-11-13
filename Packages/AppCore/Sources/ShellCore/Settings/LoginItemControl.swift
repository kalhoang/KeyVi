// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Mở khi đăng nhập" (D17, PLT-R205). `SMAppService` is the source of truth, so the toggle reflects the service
// status, never a stored preference.

/// What the General pane shows for the login item.
public struct LoginItemPresentation: Sendable, Hashable {
    /// The toggle is on when the item is registered, including while macOS still waits for approval.
    public var isOn: Bool
    /// Extra line under the toggle.
    public var note: SettingsText?
    /// "Mở Cài đặt hệ thống" next to the note.
    public var offersSystemSettings: Bool

    public init(status: LoginItemStatus, failed: Bool = false) {
        isOn = status == .enabled || status == .requiresApproval
        if failed {
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
