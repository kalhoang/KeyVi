// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four files of PLT-R1001. Each is `{ "schemaVersion": Int, "writtenBy": String, ...payload }`; unknown
// keys are preserved on rewrite (PLT-R1002) because every document keeps its raw JSON object and overlays
// known keys on encode.

public import AppModel
public import Foundation

public enum SettingsFile: String, Sendable, Hashable, CaseIterable {
    case settings = "settings.json"
    case appModes = "app-modes.json"
    case ruleOverrides = "rule-overrides.json"
    case macros = "macros.json"

    /// Current schema version written by this build. CI keeps a fixture per released version (PLT-R1005).
    public var currentSchemaVersion: Int { 1 }
}

/// Common envelope. `raw` is the full object as read (or as last written), so keys this build does not know
/// survive (PLT-R1002) and a newer-schema file can be used read-only for known fields (PLT-R1007).
public struct DocumentEnvelope<Payload: Sendable & Hashable>: Sendable, Hashable {
    public var schemaVersion: Int
    public var writtenBy: String
    public var payload: Payload
    public var raw: [String: JSONValue]

    public init(schemaVersion: Int, writtenBy: String, payload: Payload, raw: [String: JSONValue] = [:]) {
        self.schemaVersion = schemaVersion
        self.writtenBy = writtenBy
        self.payload = payload
        self.raw = raw
    }
}

/// app-modes.json: global mode, explicit per-app rules and remembered modes, most recently used first
/// (PLT-R390-R393, PRD-R21-R23). At most 1,000 remembered entries; entries with an explicit rule are never
/// evicted.
public struct AppModesDocument: Sendable, Hashable {
    public var globalMode: TypingMode
    public var apps: [AppModeEntry]
    public init(globalMode: TypingMode = .vietnamese, apps: [AppModeEntry] = []) {
        self.globalMode = globalMode
        self.apps = apps
    }

    public static let rememberedCapacity = 1_000
}

public struct AppModeEntry: Sendable, Hashable, Codable {
    public var bundle: BundleKey
    /// Explicit user rule (`nil` and `.remember` both mean "use memory").
    public var rule: PerAppRule?
    public var mode: TypingMode?
    public init(bundle: BundleKey, rule: PerAppRule? = nil, mode: TypingMode? = nil) {
        self.bundle = bundle
        self.rule = rule
        self.mode = mode
    }
}

/// rule-overrides.json entry (PLT-R541). `rule` is raw rule JSON in the 02-platform.md 5.4 schema with
/// `id` prefixed `user.`; CompatRules decodes and validates it. Kept raw so unknown rule keys survive.
public struct StoredRuleOverride: Sendable, Hashable {
    public var createdAt: Date  // "set by you on <date>"
    public var rule: JSONValue
    public init(createdAt: Date, rule: JSONValue) {
        self.createdAt = createdAt
        self.rule = rule
    }
}

/// macros.json entry (PRD-R29-R31). Content: never logged, never in diagnostics (PRD-R33).
public struct StoredMacro: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var adaptCase: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), trigger: String, expansion: String, adaptCase: Bool = true, enabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.adaptCase = adaptCase
        self.enabled = enabled
    }
}

/// Where the files live (PLT-R1001, Appendix A). Built by the App from the `Brand` helper: the folder is the
/// display name when it is ASCII, otherwise the slug (PLT-R903), and is frozen at the first public release
/// (docs/decisions/0307-settings-file-layout.md).
public struct StorageLocation: Sendable, Hashable {
    public var directory: URL  // ~/Library/Application Support/<folder>/
    public var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    public func url(for file: SettingsFile) -> URL { directory.appendingPathComponent(file.rawValue) }
    public init(directory: URL) { self.directory = directory }
}
