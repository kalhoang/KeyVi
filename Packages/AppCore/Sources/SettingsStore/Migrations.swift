// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel

/// Pure function from schema version N to N+1 over the raw JSON object (PLT-R1005). Migrations never drop
/// unknown keys.
public protocol DocumentMigration: Sendable {
    var file: SettingsFile { get }
    var fromVersion: Int { get }
    func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue]
}

public enum MigrationError: Error, Sendable, Hashable {
    case missingStep(file: SettingsFile, from: Int)
    case invalidDocument(file: SettingsFile, reason: String)
}

/// Chains registered migrations. Before migrating, the store copies the original to
/// `backups/<file>.v<N>.<timestamp>.json` and keeps the newest five per file (PLT-R1005).
public struct MigrationChain: Sendable {
    public init(_ migrations: [any DocumentMigration]) { unimplemented() }
    public func migrate(_ object: [String: JSONValue], file: SettingsFile, from: Int, to: Int) throws
        -> [String: JSONValue]
    { unimplemented() }

    /// All migrations shipped by this build (empty while every file is at version 1).
    public static let shipped = MigrationChain([])
}
