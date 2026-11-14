// SPDX-License-Identifier: GPL-3.0-or-later
//
// Records of the dev builds' continuous typing recorder (PLT-R904A, ADR 0007). Debug configuration only: Release
// never compiles this file's contents, and scripts/verify-release.sh proves it. The tap's records hold only values
// the callback already has (engine strings are retained, never built; names are static strings or small enum
// values boxed inline), so pushing them allocates nothing (PLT-R304, PLT-R305).

#if DEV_RECORDER
public import AppModel
internal import Foundation
public import RealtimeSupport

/// Everything the dev recorder writes besides the PLT-R905 key and gap records it shares with the capture.
public enum DevTraceRecord: Sendable {
    /// One engine call for one key (tap).
    case engine(DevEngineStep)
    /// A hard boundary (tap): the composition reset reason and the boundary job reason, described at drain time.
    case boundary(reason: any Sendable, job: (any Sendable)?, at: MonotonicInstant)
    /// The marker: the user saw something wrong (tap chord or menu).
    case marker(source: DevMarkerSource, at: MonotonicInstant)
    /// An edit job finished (inject thread).
    case job(DevJobRecord)
    /// A strategy fallback inside an edit job (inject thread).
    case fallback(
        sequence: UInt64, from: InjectionStrategy, to: InjectionStrategy, reason: any Sendable, at: MonotonicInstant)
    /// A focus snapshot with its decision (ax thread). Roles and bundle IDs, never titles or URLs.
    case focus(DevFocusRecord)
    /// What the focused field shows before the caret (readback queue).
    case readback(DevReadbackRecord)
    /// The VI/EN mode changed (main thread).
    case mode(DevModeRecord)
    /// The settings that change engine output (main thread), at the start of every file and on every change.
    case settings(DevSettingsSnapshot, at: MonotonicInstant)

    var timestamp: MonotonicInstant {
        switch self {
        case .engine(let step): step.at
        case .boundary(_, _, let at), .marker(_, let at), .fallback(_, _, _, _, let at), .settings(_, let at): at
        case .job(let job): job.at
        case .focus(let focus): focus.at
        case .readback(let readback): readback.at
        case .mode(let mode): mode.at
        }
    }

    /// The end of an edit job, for the readback's pause (a borrow, so a consuming push can still move the record).
    var jobEnd: MonotonicInstant? {
        if case .job(let job) = self { return job.at }
        return nil
    }
}

public enum DevMarkerSource: String, Sendable, Codable {
    case chord, menu
}

/// The engine's decision for one key: the edit, the token's display after it and the commit decision.
public struct DevEngineStep: Sendable {
    public enum Action: UInt8, Sendable {
        case passThrough, edit, editThenPassThrough
    }

    public var action: Action
    public var deleteCount: Int
    public var insert: String
    /// The active token's display after the key (empty when none). The display before is the previous step's.
    public var composing: String
    /// `CommitDecision` when the key committed a token or expanded a macro.
    public var decision: (any Sendable)?
    public var at: MonotonicInstant

    public init(
        action: Action, deleteCount: Int, insert: String, composing: String, decision: (any Sendable)?,
        at: MonotonicInstant
    ) {
        self.action = action
        self.deleteCount = deleteCount
        self.insert = insert
        self.composing = composing
        self.decision = decision
        self.at = at
    }
}

/// One finished edit job (PLT-R311-R316): what was asked, what happened and how long it took.
public struct DevJobRecord: Sendable {
    public var sequence: UInt64
    public var generation: UInt64
    /// `EditKind`: compose, backspaceRecompose, restore, macro or reentry (history re-open).
    public var kind: any Sendable
    public var strategy: InjectionStrategy
    public var outcome: StaticString
    public var deleteCount: Int
    public var insertCount: Int
    public var eventsPosted: Int
    /// From the key (job creation on the tap) to the end of the job.
    public var totalMicroseconds: UInt64
    /// From the start of execution on the inject thread to its end.
    public var runMicroseconds: UInt64
    public var at: MonotonicInstant

    public init(
        sequence: UInt64, generation: UInt64, kind: any Sendable, strategy: InjectionStrategy, outcome: StaticString,
        deleteCount: Int, insertCount: Int, eventsPosted: Int, totalMicroseconds: UInt64, runMicroseconds: UInt64,
        at: MonotonicInstant
    ) {
        self.sequence = sequence
        self.generation = generation
        self.kind = kind
        self.strategy = strategy
        self.outcome = outcome
        self.deleteCount = deleteCount
        self.insertCount = insertCount
        self.eventsPosted = eventsPosted
        self.totalMicroseconds = totalMicroseconds
        self.runMicroseconds = runMicroseconds
        self.at = at
    }
}

/// A focus snapshot (PLT-R905 roles and bundle IDs, never window titles or URLs) with the resolved decision.
public struct DevFocusRecord: Sendable, Hashable {
    public var generation: UInt64
    public var bundle: String?
    public var role: String?
    public var subrole: String?
    public var rule: String?
    public var strategy: String
    public var requireTextFocus: String
    public var axAvailability: String
    public var secure: Bool
    public var mode: String
    public var modeSource: String
    /// Engine variant: `general` or `code`, then English restore and macros.
    public var engineContext: String
    public var englishRestore: Bool
    public var macros: Bool
    public var pause: String?
    public var at: MonotonicInstant

    public init(
        generation: UInt64, bundle: String?, role: String?, subrole: String?, rule: String?, strategy: String,
        requireTextFocus: String, axAvailability: String, secure: Bool, mode: String, modeSource: String,
        engineContext: String, englishRestore: Bool, macros: Bool, pause: String?, at: MonotonicInstant
    ) {
        self.generation = generation
        self.bundle = bundle
        self.role = role
        self.subrole = subrole
        self.rule = rule
        self.strategy = strategy
        self.requireTextFocus = requireTextFocus
        self.axAvailability = axAvailability
        self.secure = secure
        self.mode = mode
        self.modeSource = modeSource
        self.engineContext = engineContext
        self.englishRestore = englishRestore
        self.macros = macros
        self.pause = pause
        self.at = at
    }
}

/// Why a readback was taken.
public enum DevReadbackReason: String, Sendable, CaseIterable {
    case backspaceEdit, commit, marker

    var bit: UInt32 {
        switch self {
        case .backspaceEdit: 1
        case .commit: 2
        case .marker: 4
        }
    }
}

/// What the readback found. Only `ok` carries text.
public enum DevReadbackStatus: String, Sendable {
    case ok
    /// The app's compat rule keeps KeyVi from relying on accessibility there: the observer reads nothing either.
    case skippedRule
    case skippedSecure
    case skippedNoField
    /// An edit job stayed queued or in flight for the whole wait: the observer never reads beside a job.
    case skippedBusy
    case unavailable
    case timedOut
    case failed
}

/// At most 64 UTF-16 units before the caret and the selected range (content, dev builds only), with the read's
/// timing (format version 2, after the incidents of 2026-11-14).
public struct DevReadbackRecord: Sendable, Hashable {
    public var reason: DevReadbackReason
    public var status: DevReadbackStatus
    public var textBeforeCaret: String?
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var bundle: String?
    public var rule: String?
    /// When the read started (after the pause).
    public var at: MonotonicInstant
    /// How long the AX calls took, timeouts included; nil when no AX call was made.
    public var durationMicroseconds: UInt64?
    /// From the first trigger to the start of the read (the pause it waited for).
    public var waitMicroseconds: UInt64?
    /// How long no key, click or job had happened when the read started; nil before any input.
    public var idleMicroseconds: UInt64?
    /// A key or click went down while the read was in flight: the read may have raced the app's handling of it.
    public var overlap = false

    public init(
        reason: DevReadbackReason, status: DevReadbackStatus, textBeforeCaret: String? = nil,
        selectionLocation: Int? = nil, selectionLength: Int? = nil, bundle: String?, rule: String?,
        at: MonotonicInstant
    ) {
        self.reason = reason
        self.status = status
        self.textBeforeCaret = textBeforeCaret
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.bundle = bundle
        self.rule = rule
        self.at = at
    }
}

/// Input as the readback's pause sees it (PLT-R904A): how many keys and clicks went down since launch, the last
/// one, and the end of the last edit job. A readback reads only after `latest` is at least 1 s old.
public struct DevInputActivity: Sendable, Hashable {
    /// Keys and clicks down since launch; a change during a read means a key overlapped it.
    public var count: UInt64
    public var lastInput: MonotonicInstant?
    public var lastJob: MonotonicInstant?

    /// The later of the last key or click and the last job end.
    public var latest: MonotonicInstant? {
        switch (lastInput, lastJob) {
        case (let input?, let job?): max(input, job)
        case (let input?, nil): input
        case (nil, let job?): job
        case (nil, nil): nil
        }
    }

    public init(count: UInt64, lastInput: MonotonicInstant?, lastJob: MonotonicInstant?) {
        self.count = count
        self.lastInput = lastInput
        self.lastJob = lastJob
    }
}

public struct DevModeRecord: Sendable, Hashable {
    public var mode: TypingMode
    public var manual: Bool
    public var bundle: String?
    public var at: MonotonicInstant

    public init(mode: TypingMode, manual: Bool, bundle: String?, at: MonotonicInstant) {
        self.mode = mode
        self.manual = manual
        self.bundle = bundle
        self.at = at
    }
}

/// Settings as name and value pairs, sorted by name; only values that change engine output or the host's
/// behaviour, and counts instead of user word lists or macro bodies.
public struct DevSettingsSnapshot: Sendable, Hashable {
    public var values: [String: String]
    public init(values: [String: String]) { self.values = values }
}
#endif
