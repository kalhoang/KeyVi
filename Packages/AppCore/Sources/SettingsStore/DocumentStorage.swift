// SPDX-License-Identifier: LicenseRef-App-Pending
//
// File operations of the settings folder (PLT-R1001, PLT-R1005, PLT-R1006): reading and classifying a document,
// atomic writes (0600 in a 0700 folder), quarantining a corrupt file as `<file>.corrupt-<timestamp>`, and the
// backups `backups/<file>.v<N>.<timestamp>.json` with the newest five kept per file. Used only from the
// `SettingsStore` actor (utility queue); holds no state of its own.

internal import AppModel
internal import Foundation

/// What a document file on disk turned out to be.
enum DocumentReadOutcome: Sendable {
    case missing
    /// Unreadable, not JSON, not an object, or without a usable `schemaVersion` (PLT-R1006 "parse failure").
    case corrupt
    case document(object: [String: JSONValue], schemaVersion: Int, data: Data)
}

/// A backup found on disk, newest first in `DocumentStorage.backups(of:)`.
struct BackupFile: Sendable, Hashable {
    var url: URL
    var schemaVersion: Int
    var date: Date
    var sequence: Int
}

struct DocumentStorage: Sendable {
    static let maxDocumentBytes = 32 * 1024 * 1024
    static let backupsKept = 5

    let location: StorageLocation
    let fileSystem: any FileSystem
    let wallClock: any WallClock

    // MARK: Reading

    func read(_ file: SettingsFile) -> DocumentReadOutcome {
        let url = location.url(for: file)
        guard fileSystem.fileExists(at: url) else { return .missing }
        guard let data = try? fileSystem.readData(at: url, maxBytes: Self.maxDocumentBytes) else { return .corrupt }
        return Self.classify(data)
    }

    static func classify(_ data: Data) -> DocumentReadOutcome {
        guard let object = try? JSONSupport.parseObject(data),
            let version = object[EnvelopeKey.schemaVersion]?.intValue, version >= 0
        else { return .corrupt }
        return .document(object: object, schemaVersion: version, data: data)
    }

    // MARK: Writing

    func write(_ object: [String: JSONValue], to file: SettingsFile) throws {
        try ensureDirectory(location.directory)
        let data = try JSONSupport.serialize(.object(object))
        try fileSystem.writeAtomically(data, to: location.url(for: file), permissions: .ownerOnlyFile)
    }

    private func ensureDirectory(_ url: URL) throws {
        guard !fileSystem.fileExists(at: url) else { return }
        try fileSystem.createDirectory(at: url, permissions: .ownerOnlyDirectory)
    }

    // MARK: Corruption (PLT-R1006)

    /// Renames the file to `<file>.corrupt-<timestamp>` next to it. Never deletes. Returns false when the
    /// rename failed (the caller still refuses to write over it).
    @discardableResult
    func quarantine(_ file: SettingsFile) -> Bool {
        let stamp = StorageTimestamp.compact(wallClock.now())
        let target = uniqueURL(in: location.directory) { suffix in "\(file.rawValue).corrupt-\(stamp)\(suffix)" }
        return (try? fileSystem.moveItem(at: location.url(for: file), to: target)) != nil
    }

    /// A quarantined copy exists: an earlier launch found the file corrupt and the user has not confirmed yet.
    func hasQuarantinedCopy(of file: SettingsFile) -> Bool {
        let prefix = "\(file.rawValue).corrupt-"
        let names = (try? fileSystem.contentsOfDirectory(at: location.directory))?.map(\.lastPathComponent) ?? []
        return names.contains { $0.hasPrefix(prefix) }
    }

    // MARK: Backups (PLT-R1005)

    /// Copies `data` (a document at `schemaVersion`) into the backups folder and prunes to the newest five.
    func writeBackup(_ data: Data, of file: SettingsFile, schemaVersion: Int) throws {
        try ensureDirectory(location.directory)
        try ensureDirectory(location.backupsDirectory)
        let stamp = StorageTimestamp.compact(wallClock.now())
        let target = uniqueURL(in: location.backupsDirectory) { suffix in
            "\(file.rawValue).v\(schemaVersion).\(stamp)\(suffix).json"
        }
        try fileSystem.writeAtomically(data, to: target, permissions: .ownerOnlyFile)
        pruneBackups(of: file)
    }

    /// Backs up the file as it is on disk now, when it is a readable document. Missing or corrupt files are
    /// left alone (a corrupt file is quarantined instead). Returns true when a backup was written.
    @discardableResult
    func backUpCurrent(_ file: SettingsFile) throws -> Bool {
        guard case .document(_, let version, let data) = read(file) else { return false }
        try writeBackup(data, of: file, schemaVersion: version)
        return true
    }

    /// Backups of `file`, newest first.
    func backups(of file: SettingsFile) -> [BackupFile] {
        let urls = (try? fileSystem.contentsOfDirectory(at: location.backupsDirectory)) ?? []
        return urls.compactMap { Self.parseBackupName($0, of: file) }
            .sorted { ($0.date, $0.sequence) > ($1.date, $1.sequence) }
    }

    /// The newest backup that parses and that `accept` can turn into a current document (for example by
    /// migrating it); backups from a newer schema are skipped.
    func newestUsableBackup(
        of file: SettingsFile, accept: ([String: JSONValue], Int) -> [String: JSONValue]?
    ) -> (object: [String: JSONValue], date: Date)? {
        for backup in backups(of: file) where backup.schemaVersion <= file.currentSchemaVersion {
            guard let data = try? fileSystem.readData(at: backup.url, maxBytes: Self.maxDocumentBytes),
                case .document(let object, let version, _) = Self.classify(data),
                let accepted = accept(object, version)
            else { continue }
            return (accepted, backup.date)
        }
        return nil
    }

    private func pruneBackups(of file: SettingsFile) {
        for stale in backups(of: file).dropFirst(Self.backupsKept) {
            try? fileSystem.removeItem(at: stale.url)
        }
    }

    /// `<file>.v<N>.<yyyyMMddTHHmmssZ>[-<k>].json`
    static func parseBackupName(_ url: URL, of file: SettingsFile) -> BackupFile? {
        let name = url.lastPathComponent
        let prefix = "\(file.rawValue).v"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(".json".count)
        guard let dot = middle.firstIndex(of: "."), let version = Int(middle[..<dot]) else { return nil }
        let stampPart = middle[middle.index(after: dot)...]
        let pieces = stampPart.split(separator: "-", maxSplits: 1)
        guard let first = pieces.first, let date = StorageTimestamp.date(compact: String(first)) else { return nil }
        let sequence = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
        return BackupFile(url: url, schemaVersion: version, date: date, sequence: sequence)
    }

    /// First name from `make("")`, `make("-1")`, `make("-2")`... that does not exist yet.
    private func uniqueURL(in directory: URL, _ make: (String) -> String) -> URL {
        for sequence in 0..<Self.maxNameAttempts {
            let url = directory.appendingPathComponent(make(sequence == 0 ? "" : "-\(sequence)"))
            if !fileSystem.fileExists(at: url) { return url }
        }
        return directory.appendingPathComponent(make("-\(Self.maxNameAttempts)"))
    }

    private static let maxNameAttempts = 10_000
}
