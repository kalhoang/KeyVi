// SPDX-License-Identifier: GPL-3.0-or-later
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
    ///
    /// Returns one result per base, in order. Names come from Info.plist (`AppLegacyStorageFolderNames`); a name
    /// that is empty, equal to `current`, or not a single path component (`/`, `.`, `..`) is ignored so a bad
    /// build setting can never move a folder outside its base.
    public static func migrate(
        current: String, legacyNames: [String], bases: [URL], fileSystem: any FileSystem
    ) -> [LegacyStorageMigration] {
        guard isSinglePathComponent(current) else { return bases.map { _ in .notNeeded } }
        let candidates = legacyNames.filter { $0 != current && isSinglePathComponent($0) }
        return bases.map { base in
            migrate(base: base, current: current, candidates: candidates, fileSystem: fileSystem)
        }
    }

    private static func migrate(
        base: URL, current: String, candidates: [String], fileSystem: any FileSystem
    ) -> LegacyStorageMigration {
        let currentURL = base.appendingPathComponent(current, isDirectory: true)
        let existingLegacy = candidates.first { name in
            fileSystem.fileExists(at: base.appendingPathComponent(name, isDirectory: true))
        }
        guard let legacy = existingLegacy else { return .notNeeded }
        guard !fileSystem.fileExists(at: currentURL) else { return .skippedBothExist(legacy: legacy) }
        let legacyURL = base.appendingPathComponent(legacy, isDirectory: true)
        do {
            // rename(2) keeps the inode and therefore its 0700 mode and contents.
            try fileSystem.moveItem(at: legacyURL, to: currentURL)
            return .moved(from: legacy)
        } catch let error as FileSystemError {
            return .failed(error)
        } catch {
            return .failed(.ioFailure(path: legacyURL.path, errno: EIO))
        }
    }

    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
