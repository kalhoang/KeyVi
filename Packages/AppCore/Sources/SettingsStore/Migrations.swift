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
    private let steps: [SettingsFile: [Int: any DocumentMigration]]

    /// When two migrations claim the same file and version, the later one in the array wins.
    public init(_ migrations: [any DocumentMigration]) {
        var steps: [SettingsFile: [Int: any DocumentMigration]] = [:]
        for migration in migrations { steps[migration.file, default: [:]][migration.fromVersion] = migration }
        self.steps = steps
    }

    /// Applies each step from `from` up to `to` in order and stamps `schemaVersion` after each one, so a step
    /// only has to transform its payload. `from == to` returns the object unchanged; going down is an error.
    public func migrate(_ object: [String: JSONValue], file: SettingsFile, from: Int, to: Int) throws
        -> [String: JSONValue]
    {
        guard from <= to else {
            throw MigrationError.invalidDocument(file: file, reason: "cannot migrate to an older schema")
        }
        var current = object
        for version in from..<to {
            guard let step = steps[file]?[version] else { throw MigrationError.missingStep(file: file, from: version) }
            current = try step.migrate(current)
            current["schemaVersion"] = .number(Double(version + 1))
        }
        return current
    }

    /// All migrations shipped by this build (empty while every file is at version 1).
    public static let shipped = MigrationChain([])
}
