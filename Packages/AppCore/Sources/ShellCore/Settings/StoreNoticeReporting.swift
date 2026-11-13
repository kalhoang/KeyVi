// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Store notices outside the Settings window (PLT-R1006, PLT-R1007). SettingsStore has no Diagnostics dependency,
// so the composition root maps each new notice to its contracts.md `LogEvent.SettingsEvent` and health event:
// the log and the diagnostics report then show a recovery or a read-only file (PLT-R1202), which prior-art
// support could not see when updates reset users' settings. The menu's status line for settings that are not
// being saved is `StatusLine.forState(storeNotices:)`.

public import Diagnostics
public import Foundation
public import SettingsStore

public enum StoreNoticeReporting {
    /// `StoreNotice.writeFailed` carries no errno; the log event's field is 0 for "not known".
    public static let unknownErrno: Int32 = 0

    /// Notices of `current` that `previous` did not have, in order: each is logged and recorded once.
    public static func added(previous: [StoreNotice], current: [StoreNotice]) -> [StoreNotice] {
        current.filter { !previous.contains($0) }
    }

    /// Nil for safe mode, which the launch logs as `LifecycleEvent.safeModeEntered`.
    public static func logEvent(_ notice: StoreNotice) -> LogEvent.SettingsEvent? {
        switch notice {
        case .recoveredFromBackup(let file, _): .recoveredFromBackup(file: file.code)
        case .corruptFileUsingDefaults(let file): .corruptFileQuarantined(file: file.code)
        case .newerSchemaReadOnly(let file, let version): .newerSchemaReadOnly(file: file.code, schemaVersion: version)
        case .writeFailed(let file): .writeFailed(file: file.code, errno: unknownErrno)
        case .safeMode: nil
        }
    }

    /// Error when the user's changes are not being saved; notice when the state is saved or only read-only.
    public static func logLevel(_ notice: StoreNotice) -> LogLevel {
        switch notice {
        case .corruptFileUsingDefaults, .writeFailed, .safeMode: .error
        case .recoveredFromBackup, .newerSchemaReadOnly: .notice
        }
    }

    /// `settingsRecovered` for a backup restore and for defaults used in place of a corrupt file;
    /// `settingsNewerSchema` for a file from a newer version. Nil for the other notices.
    public static func healthEvent(_ notice: StoreNotice, at date: Date) -> HealthEvent? {
        switch notice {
        case .recoveredFromBackup, .corruptFileUsingDefaults: HealthEvent(kind: .settingsRecovered, at: date)
        case .newerSchemaReadOnly: HealthEvent(kind: .settingsNewerSchema, at: date)
        case .writeFailed, .safeMode: nil
        }
    }
}

extension SettingsFile {
    var code: SettingsFileCode {
        switch self {
        case .settings: .settings
        case .appModes: .appModes
        case .ruleOverrides: .ruleOverrides
        case .macros: .macros
        }
    }
}
