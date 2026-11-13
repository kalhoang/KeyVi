// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Mapping of the four documents (ADR 0307, contracts.md section 7) between their raw JSON object and typed
// payloads.
//
// - `decode` is tolerant: an absent key is unset (PRD-R6), JSON `null` on an optional setting is "explicitly
//   none", and a known key whose value this build cannot read is treated as absent (and listed by
//   `skippedPaths`). One bad entry never discards its siblings.
// - `encode` overlays the payload on the raw object it was read from, so unknown keys survive at every level:
//   top level, inside `settings`, `englishRestoreLists`, `onboarding`, and inside each app, override and macro
//   entry (matched by bundle, rule id and macro id) (PLT-R1002).
// - Neither touches `schemaVersion` / `writtenBy`; the store stamps the envelope.

internal import AppModel
internal import Foundation

protocol DocumentCodec {
    associatedtype Payload: Sendable & Hashable
    static var file: SettingsFile { get }
    static var empty: Payload { get }
    static var knownKeys: Set<String> { get }
    static func decode(_ object: [String: JSONValue]) -> Payload
    static func encode(_ payload: Payload, over raw: [String: JSONValue]) -> [String: JSONValue]
    /// Dotted paths of content this build ignores: unknown keys and unreadable entries (import summary,
    /// PLT-R1010 "the skipped fields are listed").
    static func skippedPaths(in object: [String: JSONValue]) -> [String]
}

enum EnvelopeKey {
    static let schemaVersion = "schemaVersion"
    static let writtenBy = "writtenBy"
    static let all: Set<String> = [schemaVersion, writtenBy]
}

extension DocumentCodec {
    /// Top-level keys that are neither envelope nor payload.
    static func unknownTopLevelPaths(in object: [String: JSONValue], prefix: String = "") -> [String] {
        object.keys.filter { !knownKeys.contains($0) && !EnvelopeKey.all.contains($0) }.sorted().map { prefix + $0 }
    }
}

// MARK: settings.json

enum SettingsCodec: DocumentCodec {
    static let file = SettingsFile.settings
    static let empty = UserSettings()
    static let knownKeys: Set<String> = ["settings", "englishRestoreLists", "optedInRules", "onboarding"]

    static func decode(_ object: [String: JSONValue]) -> UserSettings {
        var user = UserSettings()
        let settings = object["settings"]?.objectValue ?? [:]
        for field in SettingFields.all {
            if let value = settings[field.key] { _ = field.decode(value, &user) }
        }
        let lists = object["englishRestoreLists"]?.objectValue ?? [:]
        user.keepAsTyped = lowercasedSet(lists[SettingListKey.keepAsTyped])
        user.keepVietnamese = lowercasedSet(lists[SettingListKey.keepVietnamese])
        user.optedInRules = Set(strings(object["optedInRules"]).compactMap(RuleID.init(rawValue:)))
        user.onboarding.completedVersion = object["onboarding"]?["completedVersion"]?.stringValue
        return user
    }

    static func encode(_ user: UserSettings, over raw: [String: JSONValue]) -> [String: JSONValue] {
        var object = raw
        var settings = raw["settings"]?.objectValue ?? [:]
        for field in SettingFields.all {
            guard let value = field.encode(user) else {
                settings.removeValue(forKey: field.key)
                continue
            }
            if let old = settings[field.key], field.rawMatches(old, user) { continue }
            settings[field.key] = value
        }
        object["settings"] = .object(settings)

        var lists = raw["englishRestoreLists"]?.objectValue ?? [:]
        lists[SettingListKey.keepAsTyped] = sortedArray(user.keepAsTyped)
        lists[SettingListKey.keepVietnamese] = sortedArray(user.keepVietnamese)
        object["englishRestoreLists"] = .object(lists)
        object["optedInRules"] = sortedArray(user.optedInRules.map(\.rawValue))

        var onboarding = raw["onboarding"]?.objectValue ?? [:]
        onboarding["completedVersion"] = user.onboarding.completedVersion.map(JSONValue.string)
        object["onboarding"] = .object(onboarding)
        return object
    }

    static func skippedPaths(in object: [String: JSONValue]) -> [String] {
        var paths = unknownTopLevelPaths(in: object)
        let settings = object["settings"]?.objectValue ?? [:]
        var probe = UserSettings()
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            guard let field = SettingFields.all.first(where: { $0.key == key }) else {
                paths.append("settings." + key)
                continue
            }
            if !field.decode(value, &probe) { paths.append("settings." + key) }
        }
        return paths
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    private static func lowercasedSet(_ value: JSONValue?) -> Set<String> {
        Set(strings(value).map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    private static func sortedArray(_ values: some Collection<String>) -> JSONValue {
        .array(values.sorted().map(JSONValue.string))
    }
}

// MARK: app-modes.json

enum AppModesCodec: DocumentCodec {
    static let file = SettingsFile.appModes
    static let empty = AppModesDocument()
    static let knownKeys: Set<String> = ["globalMode", "apps"]

    static func decode(_ object: [String: JSONValue]) -> AppModesDocument {
        let globalMode = object["globalMode"]?.stringValue.flatMap(TypingMode.init(rawValue:)) ?? .vietnamese
        let entries = arrayItems(object["apps"]).compactMap(entry(from:))
        return AppModesDocument(globalMode: globalMode, apps: entries).normalized()
    }

    static func encode(_ document: AppModesDocument, over raw: [String: JSONValue]) -> [String: JSONValue] {
        var rawByBundle: [String: [String: JSONValue]] = [:]
        for item in arrayItems(raw["apps"]) {
            if let object = item.objectValue, let bundle = object["bundle"]?.stringValue, rawByBundle[bundle] == nil {
                rawByBundle[bundle] = object
            }
        }
        let apps: [JSONValue] = document.apps.map { entry in
            var object = rawByBundle[entry.bundle.rawValue] ?? [:]
            object["bundle"] = .string(entry.bundle.rawValue)
            object["rule"] = entry.rule.map { .string($0.rawValue) }
            object["mode"] = entry.mode.map { .string($0.rawValue) }
            return .object(object)
        }
        var object = raw
        object["globalMode"] = .string(document.globalMode.rawValue)
        object["apps"] = .array(apps)
        return object
    }

    static func skippedPaths(in object: [String: JSONValue]) -> [String] {
        var paths = unknownTopLevelPaths(in: object, prefix: "")
        if let mode = object["globalMode"], mode.stringValue.flatMap(TypingMode.init(rawValue:)) == nil {
            paths.append("globalMode")
        }
        for (index, item) in arrayItems(object["apps"]).enumerated() where entry(from: item) == nil {
            paths.append("apps[\(index)]")
        }
        return paths
    }

    /// An entry needs a valid bundle key and at least a rule or a mode; an unreadable rule or mode is dropped.
    static func entry(from value: JSONValue) -> AppModeEntry? {
        guard let object = value.objectValue, let raw = object["bundle"]?.stringValue,
            let bundle = BundleKey(rawValue: raw)
        else { return nil }
        let rule = object["rule"]?.stringValue.flatMap(PerAppRule.init(rawValue:))
        let mode = object["mode"]?.stringValue.flatMap(TypingMode.init(rawValue:))
        guard rule != nil || mode != nil else { return nil }
        return AppModeEntry(bundle: bundle, rule: rule, mode: mode)
    }
}

extension AppModesDocument {
    /// One entry per bundle (first, most recent, wins); entries carrying neither a rule nor a mode dropped; at
    /// most `rememberedCapacity` memory-only entries, evicting the least recently used. Entries with an explicit
    /// rule are never evicted (PLT-R392).
    func normalized() -> AppModesDocument {
        var seen = Set<BundleKey>()
        var remembered = 0
        var kept: [AppModeEntry] = []
        for entry in apps where seen.insert(entry.bundle).inserted {
            if entry.hasExplicitRule {
                kept.append(entry)
            } else if entry.mode != nil, remembered < Self.rememberedCapacity {
                remembered += 1
                kept.append(entry)
            }
        }
        return AppModesDocument(globalMode: globalMode, apps: kept)
    }
}

extension AppModeEntry {
    /// `alwaysEnglish`, `alwaysVietnamese` or `ignore`; `remember` and nil both mean "use memory".
    var hasExplicitRule: Bool { rule != nil && rule != .remember }
}

// MARK: rule-overrides.json

enum RuleOverridesCodec: DocumentCodec {
    static let file = SettingsFile.ruleOverrides
    static let empty: [StoredRuleOverride] = []
    static let knownKeys: Set<String> = ["overrides"]

    static func decode(_ object: [String: JSONValue]) -> [StoredRuleOverride] {
        decodeList(arrayItems(object["overrides"]))
    }

    /// Valid entries, first one per rule id.
    static func decodeList(_ items: [JSONValue]) -> [StoredRuleOverride] {
        var seen = Set<RuleID>()
        return items.compactMap(entry(from:)).filter { seen.insert($0.ruleID).inserted }.map(\.override)
    }

    static func encode(_ overrides: [StoredRuleOverride], over raw: [String: JSONValue]) -> [String: JSONValue] {
        var object = raw
        object["overrides"] = .array(encodeList(overrides, over: arrayItems(raw["overrides"])))
        return object
    }

    static func encodeList(_ overrides: [StoredRuleOverride], over rawItems: [JSONValue]) -> [JSONValue] {
        var rawByID: [String: [String: JSONValue]] = [:]
        for item in rawItems {
            if let object = item.objectValue, let id = object["rule"]?["id"]?.stringValue, rawByID[id] == nil {
                rawByID[id] = object
            }
        }
        return overrides.map { override in
            var object = override.ruleID.flatMap { rawByID[$0.rawValue] } ?? [:]
            object["createdAt"] = .string(StorageTimestamp.iso(override.createdAt))
            object["rule"] = override.rule
            return .object(object)
        }
    }

    static func skippedPaths(in object: [String: JSONValue]) -> [String] {
        var paths = unknownTopLevelPaths(in: object)
        for (index, item) in arrayItems(object["overrides"]).enumerated() where entry(from: item) == nil {
            paths.append("overrides[\(index)]")
        }
        return paths
    }

    /// Needs `createdAt` (ISO 8601) and a rule object whose `id` is a valid `user.` rule id (PLT-R541). The
    /// rest of the rule is validated by CompatRules.
    static func entry(from value: JSONValue) -> (ruleID: RuleID, override: StoredRuleOverride)? {
        guard let object = value.objectValue,
            let created = object["createdAt"]?.stringValue.flatMap(StorageTimestamp.date(iso:)),
            let rule = object["rule"], let id = StoredRuleOverride.userRuleID(of: rule)
        else { return nil }
        return (id, StoredRuleOverride(createdAt: created, rule: rule))
    }
}

extension StoredRuleOverride {
    /// The `user.`-prefixed rule id, or nil when the rule JSON has none.
    var ruleID: RuleID? { Self.userRuleID(of: rule) }

    static func userRuleID(of rule: JSONValue) -> RuleID? {
        guard let raw = rule["id"]?.stringValue, let id = RuleID(rawValue: raw), id.isUserOverride else { return nil }
        return id
    }
}

// MARK: macros.json

enum MacrosCodec: DocumentCodec {
    static let file = SettingsFile.macros
    static let empty: [StoredMacro] = []
    static let knownKeys: Set<String> = ["macros"]

    static func decode(_ object: [String: JSONValue]) -> [StoredMacro] {
        var ids = Set<UUID>()
        return arrayItems(object["macros"]).compactMap(macro(from:)).map { macro in
            var macro = macro
            if !ids.insert(macro.id).inserted {
                macro.id = UUID()
                ids.insert(macro.id)
            }
            return macro
        }
    }

    static func encode(_ macros: [StoredMacro], over raw: [String: JSONValue]) -> [String: JSONValue] {
        var object = raw
        object["macros"] = .array(encodeList(macros, over: arrayItems(raw["macros"])))
        return object
    }

    static func encodeList(_ macros: [StoredMacro], over rawItems: [JSONValue]) -> [JSONValue] {
        var rawByID: [String: [String: JSONValue]] = [:]
        for item in rawItems {
            if let object = item.objectValue, let id = object["id"]?.stringValue, rawByID[id] == nil {
                rawByID[id] = object
            }
        }
        return macros.map { macro in
            var object = rawByID[macro.id.uuidString] ?? [:]
            object["id"] = .string(macro.id.uuidString)
            object["trigger"] = .string(macro.trigger)
            object["expansion"] = .string(macro.expansion)
            object["adaptCase"] = .bool(macro.adaptCase)
            object["enabled"] = .bool(macro.enabled)
            return .object(object)
        }
    }

    static func skippedPaths(in object: [String: JSONValue]) -> [String] {
        var paths = unknownTopLevelPaths(in: object)
        for (index, item) in arrayItems(object["macros"]).enumerated() where macro(from: item) == nil {
            paths.append("macros[\(index)]")
        }
        return paths
    }

    /// Needs `trigger` and `expansion` strings; a missing or invalid `id` gets a fresh one; `adaptCase` and
    /// `enabled` default to true (PRD-R30, PRD-R31). Content is not validated here: the editor and
    /// `MacroValidator` gate new entries, and the engine bridge skips invalid ones.
    static func macro(from value: JSONValue) -> StoredMacro? {
        guard let object = value.objectValue, let trigger = object["trigger"]?.stringValue,
            let expansion = object["expansion"]?.stringValue
        else { return nil }
        let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        return StoredMacro(
            id: id, trigger: trigger, expansion: expansion, adaptCase: bool(object["adaptCase"]) ?? true,
            enabled: bool(object["enabled"]) ?? true)
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let flag)? = value { return flag }
        return nil
    }
}

func arrayItems(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let items)? = value { return items }
    return []
}
