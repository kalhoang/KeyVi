// SPDX-License-Identifier: GPL-3.0-or-later
//
// Store notices shown at the top of the Settings window (PLT-R1006, PLT-R1007, PLT-R1009). A state recovered
// from a backup is already saved, so its notice is informational and "Đã hiểu" only dismisses it; a corrupt
// file without a backup needs "Dùng mặc định" before anything is written.

public import SettingsStore

public struct StoreNoticePresentation: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// Informational: `SettingsStore.confirmDefaults(for:)` only dismisses a recovered-from-backup notice.
        case dismiss(SettingsFile)
        /// PLT-R1006: writes the defaults over the corrupt file (it was quarantined first).
        case useDefaults(SettingsFile)
        case leaveSafeMode
        case report
        case resetAll
    }

    public let notice: StoreNotice
    public let message: String
    public let actions: [Action]
    /// Shown with a warning symbol and not only colour (PRD-R67).
    public let isWarning: Bool

    public init(_ notice: StoreNotice, appName: String, localizer: Localizer) {
        self.notice = notice
        switch notice {
        case .recoveredFromBackup(let file, let date):
            message = localizer.format(SettingsText.noticeRecovered, file.rawValue, localizer.formatDate(date))
            actions = [.dismiss(file)]
            isWarning = false
        case .corruptFileUsingDefaults(let file):
            message = localizer.format(SettingsText.noticeCorrupt, file.rawValue, appName)
            actions = [.useDefaults(file)]
            isWarning = true
        case .newerSchemaReadOnly(let file, let version):
            message = localizer.format(SettingsText.noticeNewerSchema, file.rawValue, version, appName)
            actions = []
            isWarning = false
        case .safeMode(let crashes):
            message = localizer.format(SettingsText.noticeSafeMode, appName, crashes)
            actions = [.leaveSafeMode, .resetAll, .report]  // PLT-R1009 offers reset or report
            isWarning = true
        case .writeFailed(let file):
            message = localizer.format(SettingsText.noticeWriteFailed, file.rawValue)
            actions = []
            isWarning = true
        }
    }

    public static func all(_ notices: [StoreNotice], appName: String, localizer: Localizer) -> [StoreNoticePresentation]
    {
        notices.map { StoreNoticePresentation($0, appName: appName, localizer: localizer) }
    }
}

extension StoreNoticePresentation.Action {
    public var title: SettingsText {
        switch self {
        case .dismiss: .noticeDismiss
        case .useDefaults: .noticeUseDefaults
        case .leaveSafeMode: .noticeLeaveSafeMode
        case .report: .noticeReport
        case .resetAll: .noticeReset
        }
    }

    public var control: SettingsControl {
        switch self {
        case .dismiss: .noticeDismiss
        case .useDefaults: .noticeUseDefaults
        case .leaveSafeMode: .noticeLeaveSafeMode
        case .report: .noticeReport
        case .resetAll: .noticeReset
        }
    }
}
