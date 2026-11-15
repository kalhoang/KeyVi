// SPDX-License-Identifier: GPL-3.0-or-later
//
// Own export format (PLT-R1010, PRD-R72), brand-neutral so renaming the app never breaks old exports:
//
//     {
//       "kind": "settings-export",
//       "schemaVersion": 1,
//       "writtenBy": "0.1.0",
//       "exportedAt": "2026-11-13T09:00:00Z",
//       "settings": { ...settings.json without envelope... },
//       "appModes": { ...app-modes.json without envelope... },   // optional (unticked = absent)
//       "ruleOverrides": [ ...stored overrides... ],
//       "macros": [ ...stored macros... ],                        // optional (unticked = absent)
//       "collisionMemory": [ ...collision-memory.json entries... ]  // optional (PLT-R914, merged on import; the
//                                                                   // preview counts only entries of the bundled list)
//     }
//
// File name: `<slug>-settings-YYYYMMDD.json` (slug injected by the App).

public import AppModel
public import Foundation

public struct ExportOptions: Sendable, Hashable {
    public var includeMacros: Bool  // the sheet notes that macros may contain private text
    public var includeAppModes: Bool
    /// The learned collision choices (PLT-R914, PRD-R72).
    public var includeCollisionMemory: Bool
    public init(includeMacros: Bool = true, includeAppModes: Bool = true, includeCollisionMemory: Bool = true) {
        self.includeMacros = includeMacros
        self.includeAppModes = includeAppModes
        self.includeCollisionMemory = includeCollisionMemory
    }

    /// `<slug>-settings-YYYYMMDD.json`, dated in the user's time zone.
    public static func fileName(slug: String, date: Date) -> String {
        fileName(slug: slug, date: date, timeZone: .current)
    }

    static func fileName(slug: String, date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(slug)-settings-\(day).json"
    }
}

public struct ImportPreview: Sendable, Hashable {
    public var schemaVersion: Int
    public var changedSettingKeys: [String]
    public var appEntries: Int
    public var ruleOverrides: Int
    public var macros: MacroImportPreview?
    /// The `collisionMemory` section (PLT-R914, PRD-R72); nil when the file has none.
    public var collisionMemory: CollisionMemoryImportPreview?
    /// Keys from a newer schema that this build will skip (PLT-R1010).
    public var skippedFields: [String]
    /// Opaque validated content applied by `applyImport`.
    public var content: JSONValue
}

/// What the import would do with the learned collision choices (PRD-R72, PLT-R914). The entries are checked against
/// this build's bundled list exactly as the merge checks them, so `importable` is what the merge keeps; the rest is
/// counted in `skipped`, the way the macro preview counts invalid entries.
public struct CollisionMemoryImportPreview: Sendable, Hashable {
    /// Entries the merge will add: a valid shape and a word on the bundled list.
    public var importable: Int
    /// Entries left out: a bad shape, a key repeated in the file, or a word this build's bundled list does not have.
    public var skipped: Int
    /// False while the memory is not loaded (the bundled lists failed to load): nothing can be checked or written,
    /// so nothing is imported and both counts are 0.
    public var isAvailable: Bool

    public init(importable: Int, skipped: Int, isAvailable: Bool) {
        self.importable = importable
        self.skipped = skipped
        self.isAvailable = isAvailable
    }

    /// The preview of a section: `vocabulary` nil means the memory is not loaded.
    static func of(_ items: [JSONValue], vocabulary: CollisionVocabulary?) -> (Self, CollisionMemory?) {
        guard let vocabulary else { return (Self(importable: 0, skipped: 0, isAvailable: false), nil) }
        let kept = CollisionMemoryStore.importedEntries(items).validated(against: vocabulary)
        return (Self(importable: kept.count, skipped: items.count - kept.count, isAvailable: true), kept)
    }
}

public struct ImportChoices: Sendable, Hashable {
    public var applySettings: Bool
    public var applyAppModes: Bool
    public var applyRuleOverrides: Bool
    /// Off = the macros in the file are ignored (the preview still lists them).
    public var applyMacros: Bool
    public var macroDuplicates: MacroDuplicateResolution
    /// The learned collision choices, merged by adding counters (PRD-R72).
    public var applyCollisionMemory: Bool
    public init(
        applySettings: Bool = true, applyAppModes: Bool = true, applyRuleOverrides: Bool = true,
        applyMacros: Bool = true, macroDuplicates: MacroDuplicateResolution = .keepMine,
        applyCollisionMemory: Bool = true
    ) {
        self.applySettings = applySettings
        self.applyAppModes = applyAppModes
        self.applyRuleOverrides = applyRuleOverrides
        self.applyMacros = applyMacros
        self.macroDuplicates = macroDuplicates
        self.applyCollisionMemory = applyCollisionMemory
    }
}

/// Why an import file was refused (PLT-R912). Each case is a reason the import sheet can explain (PRD-R43).
public enum SettingsImportError: Error, Sendable, Hashable {
    case tooLarge(limit: Int)
    case tooDeeplyNested(limit: Int)
    case notJSON
    case notAnObject
    /// Valid JSON, but not this app's settings export (`kind` is not `settings-export`).
    case notASettingsExport
    case invalidSchemaVersion
    /// A section has the wrong JSON type (`settings` and `appModes` must be objects, the others arrays).
    case invalidSection(String)
    /// An older export this build cannot migrate.
    case migrationFailed(fromVersion: Int)
    /// Crash-loop safe mode touches no files (PLT-R1009); leave safe mode first.
    case unavailableInSafeMode
}

/// The export format. The schema version and the import cap are public so the Settings window's import sheet
/// reads them from here instead of keeping copies (PLT-R912, PRD-R72).
public enum SettingsExportFormat {
    static let kind = "settings-export"
    /// The export schema this build writes; a file above it is "from a newer version" (PLT-R1010).
    public static let schemaVersion = 1
    /// PLT-R912: larger files are refused before parsing (`SettingsImportError.tooLarge`).
    public static let maxImportBytes = 5 * 1024 * 1024
    static let headerKeys: Set<String> = ["kind", "schemaVersion", "writtenBy", "exportedAt"]
    static let settings = "settings", appModes = "appModes", ruleOverrides = "ruleOverrides", macros = "macros"
    static let collisionMemory = "collisionMemory"
    static let sectionKeys: Set<String> = [settings, appModes, ruleOverrides, macros, collisionMemory]
}

/// The store's documents as an import is previewed against them.
struct ImportBaseline: Sendable {
    var user: UserSettings
    var macros: [StoredMacro]
    /// The bundled collision list the memory was loaded with; nil while it is not loaded (PLT-R914).
    var collisionVocabulary: CollisionVocabulary?
}

/// Validates an untrusted export (5 MB cap, bounded nesting, schema checks, no evaluation of content) and builds
/// the preview (PLT-R912, PLT-R1010). Older exports are migrated section by section; content of a newer schema
/// is read for known fields and everything else is listed in `skippedFields`.
struct SettingsImporter {
    let migrations: MigrationChain

    func preview(_ data: Data, baseline: ImportBaseline) throws(SettingsImportError) -> ImportPreview {
        let root = try parseRoot(data)
        guard let version = root[EnvelopeKey.schemaVersion]?.intValue, version >= 0 else {
            throw .invalidSchemaVersion
        }
        var skipped = root.keys.filter {
            !SettingsExportFormat.headerKeys.contains($0) && !SettingsExportFormat.sectionKeys.contains($0)
        }.sorted()
        var content: [String: JSONValue] = [:]
        var preview = ImportPreview(
            schemaVersion: version, changedSettingKeys: [], appEntries: 0, ruleOverrides: 0, macros: nil,
            skippedFields: [], content: .null)

        if let section = try objectSection(root, SettingsExportFormat.settings) {
            let object = try migrated(section, file: .settings, from: version)
            let user = SettingsCodec.decode(object)
            skipped += SettingsCodec.skippedPaths(in: object).map { "settings." + $0 }
            preview.changedSettingKeys = Self.changedKeys(from: baseline.user, to: user)
            content[SettingsExportFormat.settings] = .object(SettingsCodec.encode(user, over: [:]))
        }
        if let section = try objectSection(root, SettingsExportFormat.appModes) {
            let object = try migrated(section, file: .appModes, from: version)
            let document = AppModesCodec.decode(object)
            skipped += AppModesCodec.skippedPaths(in: object).map { "appModes." + $0 }
            preview.appEntries = document.apps.count
            content[SettingsExportFormat.appModes] = .object(AppModesCodec.encode(document, over: [:]))
        }
        if let items = try arraySection(root, SettingsExportFormat.ruleOverrides) {
            let object = try migrated(["overrides": .array(items)], file: .ruleOverrides, from: version)
            let overrides = RuleOverridesCodec.decode(object)
            skipped += RuleOverridesCodec.skippedPaths(in: object).map { "ruleOverrides." + $0 }
            preview.ruleOverrides = overrides.count
            content[SettingsExportFormat.ruleOverrides] = .array(RuleOverridesCodec.encodeList(overrides, over: []))
        }
        if let items = try arraySection(root, SettingsExportFormat.collisionMemory) {
            // PRD-R72: only what the merge keeps is counted and applied; unloaded, the section is left out.
            let (section, kept) = CollisionMemoryImportPreview.of(items, vocabulary: baseline.collisionVocabulary)
            preview.collisionMemory = section
            if let kept {
                content[SettingsExportFormat.collisionMemory] = .array(CollisionMemoryCodec.encodeEntries(kept))
            }
        }
        if let items = try arraySection(root, SettingsExportFormat.macros) {
            let object = try migrated(["macros": .array(items)], file: .macros, from: version)
            let rows = MacroJSONParser.rows(fromItems: arrayItems(object["macros"]))
            preview.macros = MacroImporter.preview(rows, existing: baseline.macros)
        }
        preview.skippedFields = skipped
        preview.content = .object(content)
        return preview
    }

    private func parseRoot(_ data: Data) throws(SettingsImportError) -> [String: JSONValue] {
        guard data.count <= SettingsExportFormat.maxImportBytes else {
            throw .tooLarge(limit: SettingsExportFormat.maxImportBytes)
        }
        let root: [String: JSONValue]
        do {
            root = try JSONSupport.parseObject(data)
        } catch {
            switch error {
            case .tooDeeplyNested(let limit): throw .tooDeeplyNested(limit: limit)
            case .notAnObject: throw .notAnObject
            case .empty, .invalidJSON: throw .notJSON
            }
        }
        guard root["kind"]?.stringValue == SettingsExportFormat.kind else { throw .notASettingsExport }
        return root
    }

    private func objectSection(_ root: [String: JSONValue], _ key: String) throws(SettingsImportError)
        -> [String: JSONValue]?
    {
        guard let value = root[key] else { return nil }
        guard case .object(let object) = value else { throw .invalidSection(key) }
        return object
    }

    private func arraySection(_ root: [String: JSONValue], _ key: String) throws(SettingsImportError) -> [JSONValue]? {
        guard let value = root[key] else { return nil }
        guard case .array(let items) = value else { throw .invalidSection(key) }
        return items
    }

    /// A section of an older export goes through the same migrations as the file it belongs to.
    private func migrated(_ payload: [String: JSONValue], file: SettingsFile, from version: Int)
        throws(SettingsImportError) -> [String: JSONValue]
    {
        guard version < file.currentSchemaVersion else { return payload }
        var object = payload
        object[EnvelopeKey.schemaVersion] = .number(Double(version))
        do {
            object = try migrations.migrate(object, file: file, from: version, to: file.currentSchemaVersion)
        } catch {
            throw .migrationFailed(fromVersion: version)
        }
        for key in EnvelopeKey.all { object.removeValue(forKey: key) }
        return object
    }

    /// Setting keys whose value would change; onboarding is machine state and never imported.
    static func changedKeys(from current: UserSettings, to imported: UserSettings) -> [String] {
        var keys = SettingFields.all.filter { !$0.isEqual(current, imported) }.map(\.key)
        if current.keepAsTyped != imported.keepAsTyped { keys.append(SettingListKey.keepAsTyped) }
        if current.keepVietnamese != imported.keepVietnamese { keys.append(SettingListKey.keepVietnamese) }
        if current.learnedWords != imported.learnedWords { keys.append(SettingListKey.learnedWords) }
        if current.optedInRules != imported.optedInRules { keys.append(SettingListKey.optedInRules) }
        return keys
    }
}
