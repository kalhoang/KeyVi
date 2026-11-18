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
    /// Focus tracking facts (PLT-R340, PLT-R380): integers and codes only, never what a field holds (PLT-R901).
    case focus(FocusEvent)
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

extension LogEvent {
    public enum FocusEvent: Sendable, Hashable {
        /// PLT-R340: a focus change the tap found after keys of the active word, in the same process or after a
        /// timed-out read, kept the word or ended it. Microseconds from the word's last key and from its first key
        /// (nil when unknown) to the new element's `changedAt`.
        case lateFocusChange(kept: Bool, sinceLastKeyMicroseconds: UInt64, sinceWordStartMicroseconds: UInt64?)
        /// PLT-R340: the worker found the new element unreadable, or without the kept word before the caret; the
        /// key passed through and the composition was reset.
        case lateFocusCheckFailed
        /// PLT-R380: one attempt to observe an app; `attempt` 0 is the first. A first attempt that installs the
        /// observer is not logged (every app switch makes one), nor a refused slow attempt before a chain's last.
        case observerAttempt(pid: Int32, attempt: Int, result: ObserverAttemptResult)
    }
}

/// What one observer attempt did (PLT-R380, PLT-R384).
public enum ObserverAttemptResult: String, Sendable, Hashable, Codable, CaseIterable {
    /// Every notification asked for was registered: by an attempt that takes all or none, or by a best-effort one
    /// that replaced an observer without focused-element changes (PLT-R380).
    case installed
    /// A best-effort attempt (the last scheduled one and the slow ones, and every attempt while an observer without
    /// focused-element changes is in place) registered what the app accepted; it may lack a notification the app
    /// refused. One that replaced such an observer has focused-element changes but lacks another name.
    case installedBestEffort
    /// The app took none of the notifications, or refused one it may take later.
    case refused
    /// No call: the app neither owns the focus nor is a running overlay app at the moment.
    case notWanted
    /// No call: the app's circuit breaker is open (PLT-R384).
    case breakerOpen
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
