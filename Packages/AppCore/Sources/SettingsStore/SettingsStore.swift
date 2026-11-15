// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings persistence (PLT-R10xx). An actor whose executor is the utility serial queue, so all reads,
// migrations and debounced atomic writes are serialized there (PLT-R1003, PLT-R203 "utility queue"). The
// executor is `QueueExecutor` (ADR 0315: `DispatchSerialQueue` is an executor only from macOS 14).
// Loading lives in SettingsStore+Load.swift, writing in SettingsStore+Persistence.swift, reset and import in
// SettingsStore+Transfer.swift.

public import AppModel
public import Dispatch
public import Foundation

/// Everything the rest of the app needs, published after every change (PLT-R1008: live, no restart).
public struct SettingsState: Sendable, Hashable {
    public var generation: UInt64
    public var user: UserSettings
    public var effective: EffectiveSettings
    public var appModes: AppModesDocument
    public var ruleOverrides: [StoredRuleOverride]
    public var macros: [StoredMacro]
    /// A file was written by a newer schema: known fields are used, nothing is written (PLT-R1007).
    public var readOnlyFiles: Set<SettingsFile>
    /// Crash-loop safe mode: defaults in memory, files untouched (PLT-R1009).
    public var safeMode: Bool
    public var notices: [StoreNotice]

    /// `effective` is derived from `user` over `DefaultSettings.v1`. For consumers' tests and previews.
    public init(
        generation: UInt64 = 0, user: UserSettings = UserSettings(), appModes: AppModesDocument = AppModesDocument(),
        ruleOverrides: [StoredRuleOverride] = [], macros: [StoredMacro] = [], readOnlyFiles: Set<SettingsFile> = [],
        safeMode: Bool = false, notices: [StoreNotice] = []
    ) {
        self.generation = generation
        self.user = user
        self.effective = user.resolved()
        self.appModes = appModes
        self.ruleOverrides = ruleOverrides
        self.macros = macros
        self.readOnlyFiles = readOnlyFiles
        self.safeMode = safeMode
        self.notices = notices
    }
}

/// User-visible notices (PLT-R1006, PLT-R1007, PLT-R1009), rendered by ShellCore.
public enum StoreNotice: Sendable, Hashable {
    case recoveredFromBackup(SettingsFile, backupDate: Date)
    case corruptFileUsingDefaults(SettingsFile)  // nothing overwritten until the user confirms
    case newerSchemaReadOnly(SettingsFile, schemaVersion: Int)
    case safeMode(recentCrashes: Int)
    /// `errno` is the POSIX code of the failed write, logged by the composition root (PLT-R1202); `noErrno` when
    /// the failure carried none. At most one per file: a later failure replaces it, a successful write clears it.
    case writeFailed(SettingsFile, errno: Int32)
}

extension StoreNotice {
    /// The `errno` of a `writeFailed` whose error had no POSIX code (for example a serialisation failure).
    public static let noErrno: Int32 = 0

    /// The POSIX code behind a failed file operation (`FileSystemError`), `noErrno` for any other error.
    static func errno(of error: any Error) -> Int32 {
        switch error as? FileSystemError {
        case .ioFailure(_, let code)?: code
        case .notFound?: ENOENT
        case .tooLarge?: EFBIG
        case nil: noErrno
        }
    }
}

public enum ResetScope: Sendable, Hashable {
    case all(includeMacros: Bool)  // PRD-R26: macros only with the separate checkbox
    case general, typing, apps  // per pane
    /// Macros pane (PRD-R26): D9 and D10 back to "unset" (PRD-R6); the list is emptied only when `includeList`
    /// (the separate checkbox). Each rewritten file is backed up first, like every reset (PLT-R1006).
    case macros(includeList: Bool)
}

public actor SettingsStore {
    /// Serial queue the store's jobs run on.
    let queue: DispatchQueue
    let executor: QueueExecutor
    let storage: DocumentStorage
    let writtenBy: String
    let migrations: MigrationChain
    let launchGuard: LaunchGuard
    let scheduler: any DebounceScheduler
    let onChange: @Sendable (SettingsState) -> Void
    /// The collision memory (PLT-R914) in the same folder, written on the same queue. InputHost loads it with the
    /// bundled list and feeds it; the Settings window reads its votes and clears it; export, import and the
    /// Typing pane reset go through this actor.
    public nonisolated let collisionMemory: CollisionMemoryStore

    var user = UserSettings()
    var appModes = AppModesDocument()
    var ruleOverrides: [StoredRuleOverride] = []
    var macros: [StoredMacro] = []
    var files: [SettingsFile: FileStatus] = [:]
    var notices: [StoreNotice] = []
    var safeMode = false
    /// Nothing is written before the first `load()`: an early write would replace files not read yet.
    var loaded = false
    var generation: UInt64 = 0
    var nextTimerToken: UInt64 = 0

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// - Parameters:
    ///   - queue: the utility serial queue (QoS utility); must be serial.
    ///   - writtenBy: app version recorded in every file (PLT-R1002).
    ///   - scheduler: debounce timers; nil = `DispatchDebounceScheduler` on `queue`. Tests pass a manual one.
    ///   - onChange: called on `queue` after each change; InputHost publishes snapshots from it, ShellCore
    ///     hops to the main actor.
    public init(
        location: StorageLocation,
        fileSystem: any FileSystem,
        wallClock: any WallClock,
        writtenBy: String,
        queue: DispatchQueue,
        migrations: MigrationChain = .shipped,
        launchGuard: LaunchGuard,
        scheduler: (any DebounceScheduler)? = nil,
        onChange: @escaping @Sendable (SettingsState) -> Void
    ) {
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.storage = DocumentStorage(location: location, fileSystem: fileSystem, wallClock: wallClock)
        self.writtenBy = writtenBy
        self.migrations = migrations
        self.launchGuard = launchGuard
        let debounce = scheduler ?? DispatchDebounceScheduler(queue: queue)
        self.scheduler = debounce
        self.onChange = onChange
        collisionMemory = CollisionMemoryStore(
            location: location, fileSystem: fileSystem, wallClock: wallClock, scheduler: debounce, writtenBy: writtenBy)
    }

    /// Loads all four files: migrate (with backups), recover from corruption (PLT-R1006), detect newer
    /// schema (PLT-R1007), honour safe mode (PLT-R1009).
    public func load() -> SettingsState {
        performLoad()
        return state
    }

    public var state: SettingsState {
        SettingsState(
            generation: generation, user: user, appModes: appModes, ruleOverrides: ruleOverrides, macros: macros,
            readOnlyFiles: Set(files.filter { $0.value.readOnly }.keys), safeMode: safeMode, notices: notices)
    }

    /// Applies an explicit change (debounced write, 1 s).
    public func updateSettings(_ change: @Sendable (inout UserSettings) -> Void) {
        var next = user
        change(&next)
        guard next != user else { return }
        user = next
        changed(.settings, after: WriteDelay.standard)
    }

    /// Per-app explicit rule from the menu or the Apps pane (PRD-R21). `nil` clears it.
    public func setAppRule(_ rule: PerAppRule?, for bundle: BundleKey) {
        let next = appModes.settingRule(rule, for: bundle)
        guard next != appModes else { return }
        appModes = next
        changed(.appModes, after: WriteDelay.standard)
    }

    /// Remembered modes and global mode from InputHost's memory; written with a 5 s debounce (PLT-R392).
    /// Explicit rules stay as set through `setAppRule`, so a copy that left the ax thread before a rule change
    /// can never revert that rule.
    public func recordAppModes(_ document: AppModesDocument) {
        let next = appModes.recordingMemory(from: document)
        guard next != appModes else { return }
        appModes = next
        changed(.appModes, after: WriteDelay.appModes)
    }

    /// Adds or replaces (same `user.` rule id) an override. A rule without a valid `user.` id is ignored; the
    /// date is kept to the second so it reads back unchanged (PLT-R541 "set by you on <date>").
    public func addRuleOverride(_ override: StoredRuleOverride) {
        guard let id = override.ruleID else { return }
        let stored = StoredRuleOverride(
            createdAt: StorageTimestamp.wholeSeconds(override.createdAt), rule: override.rule)
        var next = ruleOverrides
        if let index = next.firstIndex(where: { $0.ruleID == id }) { next[index] = stored } else { next.append(stored) }
        guard next != ruleOverrides else { return }
        ruleOverrides = next
        changed(.ruleOverrides, after: WriteDelay.standard)
    }

    public func removeRuleOverride(id: RuleID) {
        let next = ruleOverrides.filter { $0.ruleID != id }
        guard next != ruleOverrides else { return }
        ruleOverrides = next
        changed(.ruleOverrides, after: WriteDelay.standard)
    }

    /// The editor validates entries (`MacroValidator`); the store keeps them as given.
    public func replaceMacros(_ macros: [StoredMacro]) {
        guard macros != self.macros else { return }
        self.macros = macros
        changed(.macros, after: WriteDelay.standard)
    }

    /// PRD-R26. The caller offers an export first.
    public func reset(_ scope: ResetScope) { performReset(scope) }

    /// User confirmed using defaults after a corrupt file without backup (PLT-R1006): writes the in-memory state
    /// of that file, including changes made meanwhile. For a state recovered from a backup (already written at
    /// load) it only dismisses the notice.
    public func confirmDefaults(for file: SettingsFile) {
        guard status(file).awaitingConfirmation else {
            // A recovered backup is already saved: confirming only dismisses the notice.
            if notices.contains(where: { $0.isRecovery(of: file) }) {
                notices.removeAll { $0.isRecovery(of: file) }
                publish()
            }
            return
        }
        updateStatus(file) {
            $0.awaitingConfirmation = false
            $0.dirty = true
        }
        notices.removeAll { $0.isRecovery(of: file) }
        writeNow(file)
        publish()
    }

    /// Leaves safe mode and resets the launch guard.
    public func exitSafeMode() {
        launchGuard.reset()
        guard safeMode else { return }
        performLoad()
    }

    /// Writes pending changes immediately (quit, update install).
    public func flush() {
        collisionMemory.flush()
        var noticesChanged = false
        for file in SettingsFile.allCases {
            cancelPendingWrite(file)
            noticesChanged = writeNow(file) || noticesChanged
        }
        if noticesChanged { publish() }
    }

    // MARK: Collision memory (PLT-R914, PRD-R78)

    /// The learned-words sheet's rows: entries that vote for a side, never counters.
    public func learnedCollisionChoices() -> [CollisionMemoryVote] { collisionMemory.learnedChoices }

    /// One row removed (`context` nil: the any-context entry).
    public func forgetCollisionChoice(word: String, context: CollisionMemoryContext?) {
        collisionMemory.forget(word: word, context: context)
    }

    /// "Xóa tất cả" (PRD-R78): every entry, acceptance counters included; the file is deleted.
    public func clearCollisionMemory() { collisionMemory.clearAll() }

    // MARK: Export and import (PLT-R1010, PRD-R72)

    public func export(_ options: ExportOptions, now: Date) throws -> Data { try exportData(options, now: now) }
    /// Validates untrusted data (5 MB cap, schema, no evaluation, PLT-R912) and builds a preview.
    public func previewImport(_ data: Data) throws -> ImportPreview {
        try SettingsImporter(migrations: migrations).preview(data, baseline: ImportBaseline(user: user, macros: macros))
    }
    /// Backs up current files, applies, migrates older schemas, lists skipped fields of newer schemas.
    public func applyImport(_ preview: ImportPreview, choices: ImportChoices) throws {
        try performImport(preview, choices: choices)
    }
}
