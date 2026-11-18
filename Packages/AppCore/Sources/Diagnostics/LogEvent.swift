// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed logging API (PLT-R902). Every payload is an enumerated metadata type. Strings appear only as
// `StaticString` literals or `Redacted`. A lint (scripts/lint.sh, CI track) rejects string interpolation in
// any call to `log(...)`.

public import AppModel
public import Foundation

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
        /// PLT-R340: a focus change the tap found after keys of the active word kept the word or ended it.
        /// Microseconds from the word's last key and from its first key (nil when unknown) to the new snapshot's
        /// `changedAt`, and the check that decided (nil when the record carries none).
        case lateFocusChange(
            kept: Bool, sinceLastKeyMicroseconds: UInt64, sinceWordStartMicroseconds: UInt64?,
            reason: LateFocusReason? = nil)
        /// PLT-R340: the worker found the new element unreadable, or without the kept word before the caret; the
        /// key passed through and the composition was reset.
        case lateFocusCheckFailed
        /// PLT-R380: one attempt to observe an app; `attempt` 0 is the first. A first attempt that installs the
        /// observer is not logged (every app switch makes one), nor a refused slow attempt before a chain's last.
        case observerAttempt(pid: Int32, attempt: Int, result: ObserverAttemptResult)
    }
}

/// PLT-R340 amendment of 19/11/2026: which check kept the word across a focus change the tap found late, or ended
/// it. Written by the tap as `TapLogRecord.detail` (one integer, PLT-R304) and logged as `reason` (PLT-R901).
public enum LateFocusReason: UInt16, Sendable, Hashable, CaseIterable {
    /// Kept: a readable element observed within the windows; the first job checks it.
    case window = 1
    /// Kept: as `window`, but the word began right after a focus-moving trigger (PLT-R389) that the tap saw after the
    /// previous element was published, so the first-key window did not apply.
    case trigger
    /// Kept without a check: a snapshot of the same process that names no readable element.
    case unreadable
    /// Kept: the element the word began in came back (its field token) after a snapshot without one; no focus change.
    case sameElement
    /// Refused: another process (or, after a timed-out read without an app, nothing to compare with).
    case otherProcess
    /// Refused: no element where a readable one is needed (after a timed-out read without an app).
    case noElement
    /// Refused: an element whose Accessibility read timed out or failed, where a readable one is needed.
    case axUnavailable
    /// Refused: the new snapshot pauses typing (secure field, pass-through rule, no text focus).
    case paused
    /// Refused: an engine variant the word cannot continue in.
    case variant
    /// Refused: observed more than 500 ms after the word's last key.
    case lastKeyWindow
    /// Refused: observed more than 500 ms after the word's first key, while the previous snapshot named an element
    /// of the same process.
    case firstKeyWindow

    /// The stable spelling of the `reason` field.
    public var logCode: String {
        switch self {
        case .window: "window"
        case .trigger: "trigger"
        case .unreadable: "unreadable"
        case .sameElement: "sameElement"
        case .otherProcess: "otherProcess"
        case .noElement: "noElement"
        case .axUnavailable: "axUnavailable"
        case .paused: "paused"
        case .variant: "variant"
        case .lastKeyWindow: "lastKeyWindow"
        case .firstKeyWindow: "firstKeyWindow"
        }
    }

    /// The word was kept (`lateFocusKept`); otherwise it ended (`lateFocusRefused`).
    public var keeps: Bool {
        switch self {
        case .window, .trigger, .unreadable, .sameElement: true
        case .otherProcess, .noElement, .axUnavailable, .paused, .variant, .lastKeyWindow, .firstKeyWindow: false
        }
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
    /// `date` is when the event happened, for an event reported after the fact: the tap thread's records, drained
    /// later on the utility queue, often in one batch at terminate (PLT-R903). A logger that writes a timestamp uses
    /// it instead of the time of the call.
    func log(_ event: LogEvent, level: LogLevel, at date: Date)
}

extension DiagnosticsLogging {
    /// Loggers that keep no time of their own (test recorders) ignore the date.
    public func log(_ event: LogEvent, level: LogLevel, at date: Date) { log(event, level: level) }
}
