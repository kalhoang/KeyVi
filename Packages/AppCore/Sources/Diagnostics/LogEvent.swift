// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed logging API (PLT-R902). Every payload is an enumerated metadata type. Strings appear only as
// `StaticString` literals or `Redacted`. A lint (scripts/lint.sh, CI track) rejects string interpolation in
// any call to `log(...)`.

public import AppModel

public enum LogLevel: UInt8, Sendable, Hashable, Codable, Comparable {
    case debug, info, notice, error, fault
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LogCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case lifecycle, tap, pipeline, injection, focus, rules, settings, permissions, secureInput, updates,
        diagnostics, ui
}

public enum LogEvent: Sendable {
    case lifecycle(LifecycleEvent)
    case health(HealthEvent)
    case hostState(from: HostStateCode, to: HostStateCode)
    case permission(PermissionKind, PermissionState)
    case settings(SettingsEvent)
    case rules(RulesEvent)
    case update(UpdateEvent)
    /// A fixed message. `StaticString` guarantees a compile-time literal.
    case note(StaticString, category: LogCategory)
    /// A fixed message plus one redacted dynamic value.
    case redacted(StaticString, Redacted, category: LogCategory)

    public enum LifecycleEvent: Sendable, Hashable {
        case launched(AppIdentity)
        case safeModeEntered(recentCrashes: Int)
        case terminating
        case tapCreated
        case tapRemoved
    }

    public enum SettingsEvent: Sendable, Hashable {
        case loaded(schemaVersion: Int, migratedFrom: Int?)
        case recoveredFromBackup(file: SettingsFileCode)
        case corruptFileQuarantined(file: SettingsFileCode)
        case newerSchemaReadOnly(file: SettingsFileCode, schemaVersion: Int)
        case writeFailed(file: SettingsFileCode, errno: Int32)
        case imported(macros: Int, appEntries: Int, overrides: Int)
        case exported
    }

    public enum RulesEvent: Sendable, Hashable {
        case loaded(rules: Int, overrides: Int)
        case invalidShippedFileUsingEmbeddedDefaults
        case tie(winner: RuleID, loser: RuleID)
        case resolved(bundle: BundleKey, rule: RuleID?, strategy: InjectionStrategy, source: DecisionSource)
    }

    public enum UpdateEvent: Sendable, Hashable {
        case checkStarted(manual: Bool)
        case updateFound(build: String)
        case installScheduledOnQuit
        /// The keyboard was idle and secure input off: the update installs and relaunches now (PLT-R1105).
        case installingNow
        case failed(code: Int)
    }
}

/// Settings file identifiers for logs (no paths).
public enum SettingsFileCode: String, Sendable, Hashable, Codable {
    case settings, appModes, ruleOverrides, macros
}

/// Logging entry point for main, ax, inject and utility threads. Never blocks: the record is handed to the
/// utility queue. The tap thread does not use this API; it writes `TapLogRecord`s (PLT-R304).
public protocol DiagnosticsLogging: Sendable {
    func log(_ event: LogEvent, level: LogLevel)
}
