// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Reset (PRD-R26), export and import (PLT-R1010, PRD-R72). Reset and import are explicit user actions: each
// affected file is copied to backups first, then rewritten at once at the current schema. That is the only
// way a newer-schema (read-only) or unconfirmed corrupt file gets replaced, and the backup keeps the previous
// content recoverable (PLT-R1006 "never wipe").

internal import AppModel
internal import Foundation

extension SettingsStore {
    // MARK: Reset

    func performReset(_ scope: ResetScope) {
        // Reset is what the safe-mode notice offers; macros the user keeps must come from disk, so leave
        // safe mode (reading the files again) first.
        if safeMode {
            launchGuard.reset()
            performLoad()
        }
        let affected = scope.files
        prepareExplicitRewrite(affected)
        applyReset(scope)
        for file in SettingsFile.allCases where affected.contains(file) { writeNow(file) }
        publish()
    }

    private func applyReset(_ scope: ResetScope) {
        switch scope {
        case .all(let includeMacros):
            let onboarding = user.onboarding  // not a preference: resetting must not replay onboarding
            user = UserSettings()
            user.onboarding = onboarding
            appModes = AppModesDocument(globalMode: appModes.globalMode)
            ruleOverrides = []
            if includeMacros { macros = [] }
        case .general:
            unset(.general)
        case .typing:
            unset(.typing)
            user.keepAsTyped = []
            user.keepVietnamese = []
        case .apps:
            unset(.apps)
            user.optedInRules = []
            appModes = AppModesDocument(globalMode: appModes.globalMode)
            ruleOverrides = []
        }
    }

    private func unset(_ group: SettingGroup) {
        for field in SettingFields.all where field.group == group { field.unset(&user) }
    }

    /// Backs up what is on disk now and lifts every write block of the files about to be replaced.
    func prepareExplicitRewrite(_ affected: Set<SettingsFile>) {
        for file in SettingsFile.allCases where affected.contains(file) {
            if !safeMode { _ = try? storage.backUpCurrent(file) }
            updateStatus(file) {
                $0.readOnly = false
                $0.awaitingConfirmation = false
                $0.writeBlocked = false
                $0.backedUpThisSession = true
                $0.dirty = true
            }
            cancelPendingWrite(file)
            notices.removeAll { $0.concerns(file) }
        }
    }

    // MARK: Export

    /// Known fields only, without the files' unknown keys: the export claims schema version 1 and must not
    /// carry content this build cannot vouch for.
    func exportData(_ options: ExportOptions, now: Date) throws -> Data {
        var root: [String: JSONValue] = [
            "kind": .string(SettingsExportFormat.kind),
            EnvelopeKey.schemaVersion: .number(Double(SettingsExportFormat.schemaVersion)),
            EnvelopeKey.writtenBy: .string(writtenBy),
            "exportedAt": .string(StorageTimestamp.iso(now)),
            SettingsExportFormat.settings: .object(SettingsCodec.encode(user, over: [:])),
            SettingsExportFormat.ruleOverrides: .array(RuleOverridesCodec.encodeList(ruleOverrides, over: [])),
        ]
        if options.includeAppModes {
            root[SettingsExportFormat.appModes] = .object(AppModesCodec.encode(appModes, over: [:]))
        }
        if options.includeMacros {
            root[SettingsExportFormat.macros] = .array(MacrosCodec.encodeList(macros, over: []))
        }
        return try JSONSupport.serialize(.object(root))
    }

    // MARK: Import

    func performImport(_ preview: ImportPreview, choices: ImportChoices) throws(SettingsImportError) {
        guard !safeMode else { throw .unavailableInSafeMode }
        if !loaded { performLoad() }
        let content = preview.content.objectValue ?? [:]
        let importedUser =
            choices.applySettings ? content[SettingsExportFormat.settings]?.objectValue.map(SettingsCodec.decode) : nil
        let importedModes =
            choices.applyAppModes ? content[SettingsExportFormat.appModes]?.objectValue.map(AppModesCodec.decode) : nil
        let importedOverrides =
            choices.applyRuleOverrides
            ? content[SettingsExportFormat.ruleOverrides].map { RuleOverridesCodec.decodeList(arrayItems($0)) } : nil
        let macroPreview = choices.applyMacros ? preview.macros : nil

        var affected = Set<SettingsFile>()
        if importedUser != nil { affected.insert(.settings) }
        if importedModes != nil { affected.insert(.appModes) }
        if importedOverrides != nil { affected.insert(.ruleOverrides) }
        if macroPreview != nil { affected.insert(.macros) }
        guard !affected.isEmpty else { return }

        prepareExplicitRewrite(affected)
        if var imported = importedUser {
            imported.onboarding = user.onboarding  // machine state: a new Mac still needs onboarding
            user = imported
        }
        if let importedModes { appModes = appModes.merging(imported: importedModes) }
        if let importedOverrides { ruleOverrides = Self.merging(ruleOverrides, imported: importedOverrides) }
        if let macroPreview {
            macros = MacroImporter.merge(macroPreview, into: macros, resolution: choices.macroDuplicates)
        }
        for file in SettingsFile.allCases where affected.contains(file) { writeNow(file) }
        publish()
    }

    /// Imported overrides replace the ones with the same rule id in place; others are appended.
    static func merging(_ current: [StoredRuleOverride], imported: [StoredRuleOverride]) -> [StoredRuleOverride] {
        var result = current
        for override in imported {
            if let index = result.firstIndex(where: { $0.ruleID == override.ruleID }) {
                result[index] = override
            } else {
                result.append(override)
            }
        }
        return result
    }
}

extension ResetScope {
    var files: Set<SettingsFile> {
        switch self {
        case .all(let includeMacros):
            includeMacros ? Set(SettingsFile.allCases) : [.settings, .appModes, .ruleOverrides]
        case .general, .typing: [.settings]
        case .apps: [.settings, .appModes, .ruleOverrides]
        }
    }
}
