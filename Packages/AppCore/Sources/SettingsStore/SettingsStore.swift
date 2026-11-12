// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings persistence (PLT-R10xx). An actor whose executor is the utility serial queue, so all reads,
// migrations and debounced atomic writes are serialized there (PLT-R1003, PLT-R203 "utility queue").

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
}

/// User-visible notices (PLT-R1006, PLT-R1007, PLT-R1009), rendered by ShellCore.
public enum StoreNotice: Sendable, Hashable {
    case recoveredFromBackup(SettingsFile, backupDate: Date)
    case corruptFileUsingDefaults(SettingsFile)  // nothing overwritten until the user confirms
    case newerSchemaReadOnly(SettingsFile, schemaVersion: Int)
    case safeMode(recentCrashes: Int)
    case writeFailed(SettingsFile)
}

public enum ResetScope: Sendable, Hashable {
    case all(includeMacros: Bool)  // PRD-R26: macros only with the separate checkbox
    case general, typing, apps  // per pane
}

public actor SettingsStore {
    private let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - Parameters:
    ///   - queue: the utility serial queue (QoS utility).
    ///   - writtenBy: app version recorded in every file (PLT-R1002).
    ///   - onChange: called on `queue` after each change; InputHost publishes snapshots from it, ShellCore
    ///     hops to the main actor.
    public init(
        location: StorageLocation,
        fileSystem: any FileSystem,
        wallClock: any WallClock,
        writtenBy: String,
        queue: DispatchSerialQueue,
        migrations: MigrationChain = .shipped,
        launchGuard: LaunchGuard,
        onChange: @escaping @Sendable (SettingsState) -> Void
    ) {
        self.queue = queue
        unimplemented()
    }

    /// Loads all four files: migrate (with backups), recover from corruption (PLT-R1006), detect newer
    /// schema (PLT-R1007), honour safe mode (PLT-R1009).
    public func load() -> SettingsState { unimplemented() }

    public var state: SettingsState { unimplemented() }

    /// Applies an explicit change (debounced write, 1 s).
    public func updateSettings(_ change: @Sendable (inout UserSettings) -> Void) { unimplemented() }

    /// Per-app explicit rule from the menu or the Apps pane (PRD-R21). `nil` clears it.
    public func setAppRule(_ rule: PerAppRule?, for bundle: BundleKey) { unimplemented() }

    /// Remembered modes and global mode from InputHost's memory; written with a 5 s debounce (PLT-R392).
    public func recordAppModes(_ document: AppModesDocument) { unimplemented() }

    public func addRuleOverride(_ override: StoredRuleOverride) { unimplemented() }
    public func removeRuleOverride(id: RuleID) { unimplemented() }
    public func replaceMacros(_ macros: [StoredMacro]) { unimplemented() }

    /// PRD-R26. The caller offers an export first.
    public func reset(_ scope: ResetScope) { unimplemented() }

    /// User confirmed using defaults after a corrupt file without backup (PLT-R1006).
    public func confirmDefaults(for file: SettingsFile) { unimplemented() }

    /// Leaves safe mode and resets the launch guard.
    public func exitSafeMode() { unimplemented() }

    /// Writes pending changes immediately (quit, update install).
    public func flush() { unimplemented() }

    // MARK: Export and import (PLT-R1010, PRD-R72)

    public func export(_ options: ExportOptions, now: Date) throws -> Data { unimplemented() }
    /// Validates untrusted data (5 MB cap, schema, no evaluation, PLT-R912) and builds a preview.
    public func previewImport(_ data: Data) throws -> ImportPreview { unimplemented() }
    /// Backs up current files, applies, migrates older schemas, lists skipped fields of newer schemas.
    public func applyImport(_ preview: ImportPreview, choices: ImportChoices) throws { unimplemented() }
}
