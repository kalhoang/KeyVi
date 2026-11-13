// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Export and import sheets (PLT-R1010, PRD-R72): what the export contains, the import summary (changed settings,
// counts, skipped fields of a newer schema) and a plain explanation for every refused file (PRD-R43).

public import Foundation
public import SettingsStore

/// The import sheet before the user confirms.
public struct ImportSummary: Sendable, Hashable {
    public let preview: ImportPreview
    public var choices: ImportChoices

    public init(preview: ImportPreview) {
        self.preview = preview
        choices = ImportChoices()
    }

    /// Above the export schema this build writes (PLT-R1010); the store owns the number.
    public var isNewerSchema: Bool { preview.schemaVersion > SettingsExportFormat.schemaVersion }

    /// Which sections the file has, so the sheet offers a checkbox only for those.
    public var hasSettings: Bool { preview.content["settings"] != nil }
    public var hasAppModes: Bool { preview.content["appModes"] != nil }
    public var hasRuleOverrides: Bool { preview.content["ruleOverrides"] != nil }
    public var hasMacros: Bool { preview.macros != nil }
    public var hasDuplicateMacros: Bool { !(preview.macros?.duplicates.isEmpty ?? true) }

    /// Nothing would be applied with the current choices.
    public var isEmptySelection: Bool {
        !((choices.applySettings && hasSettings) || (choices.applyAppModes && hasAppModes)
            || (choices.applyRuleOverrides && hasRuleOverrides) || (choices.applyMacros && hasMacros))
    }

    /// Summary lines in display order: changed settings, app entries, overrides, macro counts, skipped fields.
    public func lines(_ localizer: Localizer) -> [String] {
        var lines: [String] = []
        if hasSettings {
            let names = preview.changedSettingKeys.map { SettingNames.name(forKey: $0, localizer) }
            lines.append(
                names.isEmpty
                    ? localizer.string(SettingsText.importNoSettingsChanged)
                    : localizer.format(SettingsText.importSettingsChanged, ListFormat.join(names, localizer)))
        }
        if hasAppModes { lines.append(localizer.format(SettingsText.importAppEntries, preview.appEntries)) }
        if hasRuleOverrides { lines.append(localizer.format(SettingsText.importRuleOverrides, preview.ruleOverrides)) }
        if let macros = preview.macros {
            lines.append(
                localizer.format(
                    SettingsText.importMacros, macros.new.count, macros.duplicates.count, macros.invalid.count))
        }
        if isNewerSchema { lines.append(localizer.string(SettingsText.importNewerSchema)) }
        if !preview.skippedFields.isEmpty {
            lines.append(
                localizer.format(SettingsText.importSkipped, ListFormat.join(preview.skippedFields, localizer)))
        }
        return lines
    }
}

/// User-facing names of `settings.json` keys for the import summary.
public enum SettingNames {
    public static func name(forKey key: String, _ localizer: Localizer) -> String {
        if let item = SettingItem.allCases.first(where: { $0.settingsKey == key }) {
            return localizer.string(item.title)
        }
        switch key {
        case "firstSeenAppMode": return localizer.string(SettingsText.nameFirstSeenAppMode)
        case "macrosInEnglishMode": return localizer.string(SettingsText.nameMacrosInEnglishMode)
        case "optedInRules": return localizer.string(SettingsText.nameOptedInRules)
        default: return key
        }
    }
}

/// Size limits in the copy, taken from the limit itself so the text follows a changed cap.
enum SizeText {
    static func megabytes(_ bytes: Int, _ localizer: Localizer) -> String {
        localizer.formatNumber(max(1, bytes / (1024 * 1024)))
    }
}

enum ListFormat {
    /// Locale-aware list ("a, b và c" / "a, b, and c").
    static func join(_ items: [String], _ localizer: Localizer) -> String {
        items.formatted(.list(type: .and).locale(localizer.locale))
    }
}

/// Why an import was refused, as one sentence (PRD-R43: what happened and what to do).
public enum SettingsImportMessage {
    public static func text(for error: SettingsImportError, appName: String, _ localizer: Localizer) -> String {
        switch error {
        case .tooLarge(let limit):
            localizer.format(SettingsText.importErrorTooLarge, SizeText.megabytes(limit, localizer))
        case .tooDeeplyNested, .notJSON, .notAnObject: localizer.string(SettingsText.importErrorFormat)
        case .notASettingsExport: localizer.format(SettingsText.importErrorNotExport, appName)
        case .invalidSchemaVersion: localizer.string(SettingsText.importErrorVersion)
        case .invalidSection(let section): localizer.format(SettingsText.importErrorSection, section)
        case .migrationFailed(let version): localizer.format(SettingsText.importErrorMigration, version)
        case .unavailableInSafeMode: localizer.format(SettingsText.importErrorSafeMode, appName)
        }
    }

    /// Any other error (for example the file could not be read).
    public static func text(for error: any Error, appName: String, _ localizer: Localizer) -> String {
        if let error = error as? SettingsImportError { return text(for: error, appName: appName, localizer) }
        return localizer.string(SettingsText.importErrorUnreadable)
    }
}

/// Macro list export (PRD-R2 "macros with import and export"): a bare macros document the importer reads as
/// `appExport`. Content is user data: written only to the file the user picked (PRD-R33).
public enum MacroExport {
    struct Document: Codable {
        var schemaVersion: Int
        var macros: [StoredMacro]
    }

    public static func data(_ macros: [StoredMacro]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Document(schemaVersion: 1, macros: macros))
    }

    /// `<slug>-macros-YYYYMMDD.json`, dated like the settings export.
    public static func fileName(slug: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(slug)-macros-\(day).json"
    }
}
