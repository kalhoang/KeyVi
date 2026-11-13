// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Every write the Settings window makes, as calls on the `SettingsStore` actor (utility queue). Each command
// returns the store's state afterwards, so the window shows the result even before the composition root's
// `onChange` hop arrives (PRD-R27: changes apply immediately).

public import AppModel
public import Foundation
public import SettingsStore

public struct SettingsCommands: Sendable {
    public let store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    public func state() async -> SettingsState { await store.state }

    /// PRD-R6: an explicit choice, kept even when equal to today's default.
    public func apply(_ edit: SettingsEdit) async -> SettingsState {
        await store.updateSettings { edit.apply(to: &$0) }
        return await store.state
    }

    /// PRD-R21 rule from the Apps pane; `.remember` clears the explicit rule.
    public func setRule(_ rule: PerAppRule, for bundle: BundleKey) async -> SettingsState {
        await store.setAppRule(rule == .remember ? nil : rule, for: bundle)
        return await store.state
    }

    /// PLT-R540: writes or removes this app's compatibility override.
    public func setCompatibility(_ choice: CompatibilityModeChoice, for bundle: BundleKey, at date: Date)
        async -> SettingsState
    {
        switch choice.command(for: bundle, at: date) {
        case .add(let stored): await store.addRuleOverride(stored)
        case .remove(let id): await store.removeRuleOverride(id: id)
        }
        return await store.state
    }

    /// PRD-R26, after the user confirmed (and was offered an export).
    public func perform(_ plan: ResetPlan) async -> SettingsState {
        if let scope = plan.storeScope { await store.reset(scope) }
        if plan.unsetsMacroSwitches {
            await store.updateSettings {
                $0.macrosEnabled = .unset
                $0.macrosInEnglishMode = .unset
            }
        }
        if plan.deletesMacroList { await store.replaceMacros([]) }
        return await store.state
    }

    /// The editor has validated the list (MacroValidator and the engine).
    public func saveMacros(_ macros: [StoredMacro]) async -> SettingsState {
        await store.replaceMacros(macros)
        return await store.state
    }

    public func export(_ options: ExportOptions, now: Date) async throws -> Data {
        try await store.export(options, now: now)
    }

    public func previewImport(_ data: Data) async throws -> ImportPreview { try await store.previewImport(data) }

    public func applyImport(_ summary: ImportSummary) async throws -> SettingsState {
        try await store.applyImport(summary.preview, choices: summary.choices)
        return await store.state
    }

    /// Notice buttons (PLT-R1006, PLT-R1009). Report and reset are opened by the window.
    public func perform(_ action: StoreNoticePresentation.Action) async -> SettingsState {
        switch action {
        case .dismiss(let file), .useDefaults(let file): await store.confirmDefaults(for: file)
        case .leaveSafeMode: await store.exitSafeMode()
        case .report, .resetAll: break
        }
        return await store.state
    }
}
