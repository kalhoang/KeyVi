// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One-time move of the storage folders after a product rename (ADR 0307, review finding on the temporary
// name). Runs at launch before `SettingsStore.load`, on the utility queue. Workstream W1-B.

public import AppModel
public import Foundation

public enum LegacyStorageMigration: Sendable, Hashable {
    /// The current folder exists, or no legacy folder exists: nothing to do.
    case notNeeded
    /// `from` (a legacy folder name) was moved to the current name.
    case moved(from: String)
    /// Both the current and a legacy folder exist: the current one wins, the legacy one is left untouched.
    case skippedBothExist(legacy: String)
    case failed(FileSystemError)
}

public enum LegacyStorageMigrator {
    /// For each base (`~/Library/Application Support`, `~/Library/Logs`): if `<base>/<current>` does not exist
    /// and `<base>/<legacy>` exists for the first name in `legacyNames` (newest first), renames it to
    /// `<base>/<current>` keeping permissions (0700). Never merges, never deletes.
    public static func migrate(
        current: String, legacyNames: [String], bases: [URL], fileSystem: any FileSystem
    ) -> [LegacyStorageMigration] { unimplemented() }
}
