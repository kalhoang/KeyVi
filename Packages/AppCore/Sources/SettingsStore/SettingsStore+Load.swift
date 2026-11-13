// SPDX-License-Identifier: GPL-3.0-or-later
//
// Loading the four documents (PLT-R1005, PLT-R1006, PLT-R1007, PLT-R1009). Per file:
// - missing, no quarantined copy: defaults (first launch);
// - missing but a `.corrupt-*` copy exists: an earlier launch found it corrupt and the user never confirmed, so
//   recovery runs again (otherwise the notice would vanish and defaults would silently stick);
// - corrupt: quarantined as `.corrupt-<timestamp>`, then the newest usable backup is loaded and written back at
//   once (the broken file is safe under its new name, so later changes persist; the notice stays until
//   `confirmDefaults(for:)` or the next launch), else defaults in memory with nothing written until the user
//   confirms. When the rename fails, nothing ever writes over the file in this launch;
// - newer schema: known fields used read-only, never rewritten;
// - older schema: original copied to backups first, migrated, then written once.

internal import AppModel
internal import Foundation

extension SettingsStore {
    func performLoad() {
        for file in SettingsFile.allCases { cancelPendingWrite(file) }
        files = [:]
        notices = []
        loaded = true
        if launchGuard.isSafeModeActive {
            enterSafeMode()
            publish()
            return
        }
        safeMode = false
        user = loadDocument(SettingsCodec.self)
        appModes = loadDocument(AppModesCodec.self)
        ruleOverrides = loadDocument(RuleOverridesCodec.self)
        macros = loadDocument(MacrosCodec.self)
        for file in SettingsFile.allCases where status(file).dirty { writeNow(file) }
        publish()
    }

    /// Defaults in memory and no file access at all: the crash may come from reading a file (PLT-R1009).
    private func enterSafeMode() {
        safeMode = true
        user = SettingsCodec.empty
        appModes = AppModesCodec.empty
        ruleOverrides = RuleOverridesCodec.empty
        macros = MacrosCodec.empty
        notices = [.safeMode(recentCrashes: launchGuard.recentCrashes)]
    }

    private func loadDocument<Codec: DocumentCodec>(_ codec: Codec.Type) -> Codec.Payload {
        let file = Codec.file
        switch storage.read(file) {
        case .missing:
            guard storage.hasQuarantinedCopy(of: file) else {
                files[file] = FileStatus()
                return Codec.empty
            }
            return recover(codec, quarantined: true)
        case .corrupt:
            return recover(codec, quarantined: storage.quarantine(file))
        case .document(let object, let version, let data):
            return open(codec, object: object, version: version, data: data)
        }
    }

    private func open<Codec: DocumentCodec>(
        _ codec: Codec.Type, object: [String: JSONValue], version: Int, data: Data
    ) -> Codec.Payload {
        let file = Codec.file
        let current = file.currentSchemaVersion
        if version == current {
            files[file] = FileStatus(raw: object)
            return Codec.decode(object)
        }
        if version > current {
            files[file] = FileStatus(raw: object, readOnly: true)
            addNotice(.newerSchemaReadOnly(file, schemaVersion: version))
            return Codec.decode(object)
        }
        guard let migrated = try? migrations.migrate(object, file: file, from: version, to: current) else {
            return recover(codec, quarantined: storage.quarantine(file))
        }
        var status = FileStatus(raw: migrated, dirty: true)
        do {
            try storage.writeBackup(data, of: file, schemaVersion: version)
        } catch {
            // Without the backup the original must stay as it is (PLT-R1005); retried at the next launch.
            status.writeBlocked = true
            addNotice(.writeFailed(file))
        }
        files[file] = status
        return Codec.decode(migrated)
    }

    /// `quarantined` is false when the corrupt file could not be renamed: it is then still the only copy and
    /// nothing may write over it (PLT-R1006 "never wipe").
    private func recover<Codec: DocumentCodec>(_ codec: Codec.Type, quarantined: Bool) -> Codec.Payload {
        let file = Codec.file
        let migrations = self.migrations
        let backup = storage.newestUsableBackup(of: file) { object, version in
            try? migrations.migrate(object, file: file, from: version, to: file.currentSchemaVersion)
        }
        guard let backup else {
            files[file] = FileStatus(awaitingConfirmation: true, writeBlocked: !quarantined)
            addNotice(.corruptFileUsingDefaults(file))
            return Codec.empty
        }
        // PLT-R1006 asks for confirmation only before defaults replace the user's data; a restored backup is the
        // user's data, so it is written back now (the backup itself is already on disk).
        files[file] = FileStatus(raw: backup.object, writeBlocked: !quarantined, dirty: true)
        addNotice(.recoveredFromBackup(file, backupDate: backup.date))
        return Codec.decode(backup.object)
    }
}
