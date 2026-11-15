// SPDX-License-Identifier: GPL-3.0-or-later
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
        // Reset is what the safe-mode notice offers. Whatever the user keeps (macros, other panes) must come
        // from disk, so leave safe mode by reading the files again; erasing everything needs nothing from them,
        // so that path skips the reload whose content may be what crashed (PLT-R1009).
        if safeMode {
            launchGuard.reset()
            if case .all(includeMacros: true) = scope { leaveSafeModeWithoutReading() } else { performLoad() }
        }
        let affected = scope.files
        prepareExplicitRewrite(affected)
        applyReset(scope)
        for file in SettingsFile.allCases where affected.contains(file) { writeNow(file) }
        publish()
    }

    /// Empty documents in memory, every file writable. Onboarding state is not known without reading the file,
    /// so a full reset from safe mode behaves like a fresh install (each file is still backed up first).
    private func leaveSafeModeWithoutReading() {
        safeMode = false
        notices = []
        files = [:]
    }

    private func applyReset(_ scope: ResetScope) {
        switch scope {
        case .all(let includeMacros):
            let onboarding = user.onboarding  // not a preference: resetting must not replay onboarding
            user = UserSettings()
            user.onboarding = onboarding
            forgetRawValues(of: SettingFields.all)
            appModes = AppModesDocument(globalMode: appModes.globalMode)
            ruleOverrides = []
            if includeMacros { macros = [] }
            collisionMemory.clearAll()  // PLT-R914
        case .general:
            unset(.general)
        case .typing:
            unset(.typing)
            user.keepAsTyped = []
            user.keepVietnamese = []
            user.learnedWords = []  // ENG-R862: learned entries are shown and reset with the Typing pane lists
            collisionMemory.clearAll()  // PLT-R914: the learned collision choices go with the Typing pane
        case .apps:
            unset(.apps)
            user.optedInRules = []
            appModes = AppModesDocument(globalMode: appModes.globalMode)
            ruleOverrides = []
        case .macros(let includeList):
            unset(.macros)
            if includeList { macros = [] }
        }
    }

    private func unset(_ group: SettingGroup) {
        let fields = SettingFields.all.filter { $0.group == group }
        for field in fields { field.unset(&user) }
        forgetRawValues(of: fields)
    }

    /// The writer keeps a value this build cannot read while its field is unset (PRD-R6); a reset is the user
    /// explicitly dropping it, so it leaves the raw overlay too.
    private func forgetRawValues(of fields: [SettingField]) {
        updateStatus(.settings) { status in
            guard var settings = status.raw["settings"]?.objectValue else { return }
            for field in fields { settings.removeValue(forKey: field.key) }
            status.raw["settings"] = .object(settings)
        }
    }

    /// Backs up what is on disk now and lifts the write blocks of the files about to be replaced. A corrupt file
    /// is quarantined instead of backed up; if it still cannot be renamed it stays blocked (PLT-R1006).
    func prepareExplicitRewrite(_ affected: Set<SettingsFile>) {
        for file in SettingsFile.allCases where affected.contains(file) {
            let secured = secureCurrent(file)
            updateStatus(file) {
                $0.readOnly = false
                $0.awaitingConfirmation = false
                $0.writeBlocked = !secured
                $0.dirty = true
            }
            cancelPendingWrite(file)
            if secured { notices.removeAll { $0.concerns(file) } }
        }
    }

    /// Keeps the current on-disk content recoverable before an explicit rewrite. A failed rotation backup does
    /// not stop the user's action (as for ordinary writes); only an unrenamable corrupt file does.
    private func secureCurrent(_ file: SettingsFile) -> Bool {
        switch storage.read(file) {
        case .missing:
            return true
        case .corrupt:
            return storage.quarantine(file)
        case .document(_, let version, let data):
            try? storage.writeBackup(data, of: file, schemaVersion: version)
            return true
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
        if options.includeCollisionMemory, let section = collisionMemory.exportSection() {
            root[SettingsExportFormat.collisionMemory] = section
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
        // PRD-R72: the learned collision choices merge by adding counters; their file is not a settings file.
        if choices.applyCollisionMemory, let section = content[SettingsExportFormat.collisionMemory] {
            collisionMemory.merge(CollisionMemoryStore.importedEntries(arrayItems(section)))
        }

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
        case .macros(let includeList): includeList ? [.settings, .macros] : [.settings]
        }
    }
}
