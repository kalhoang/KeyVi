// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Reset confirmation (PRD-R26: confirmation, export offer, separate macros checkbox), export sheet (PLT-R1010:
// macros and per-app modes can be unticked, with the privacy note) and import summary (PLT-R1010: changes,
// counts, skipped fields, duplicate choice, backup note).

import AppModel
import SettingsStore
import ShellCore
import SwiftUI

struct ResetSheet: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        if let request = model.resetRequest {
            VStack(alignment: .leading, spacing: 12) {
                PaneHeading(text: request.title(localizer))
                Text(verbatim: localizer.string(request.body)).fixedSize(horizontal: false, vertical: true)
                if request.offersMacroDeletion {
                    Toggle(isOn: deleteMacros) { Text(verbatim: localizer.string(SettingsText.resetIncludeMacros)) }
                        .settingsAccessibility(SettingsControl.resetIncludeMacros, localizer)
                }
                Text(verbatim: localizer.string(SettingsText.resetExportOffer)).font(.callout).foregroundStyle(
                    .secondary)
                if let file = request.exportedFileName {
                    IssueLine(symbol: "checkmark.circle", text: localizer.format(SettingsText.resetExported, file))
                }
                HStack {
                    Button(action: model.exportBeforeReset) {
                        Text(verbatim: localizer.string(SettingsText.resetExportFirst))
                    }
                    .settingsAccessibility(SettingsControl.resetExportFirst, localizer)
                    Spacer()
                    Button(action: { model.resetRequest = nil }) {
                        Text(verbatim: localizer.string(SettingsText.resetCancel))
                    }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(SettingsControl.resetCancel, localizer)
                    Button(action: model.confirmReset) { Text(verbatim: localizer.string(SettingsText.resetConfirm)) }
                        .settingsAccessibility(SettingsControl.resetConfirm, localizer)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private var deleteMacros: Binding<Bool> {
        Binding(get: { model.resetRequest?.deleteMacros ?? false }, set: { model.resetRequest?.deleteMacros = $0 })
    }
}

struct ExportSheet: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(SettingsText.exportTitle))
            Text(verbatim: localizer.string(SettingsText.exportBody)).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: option(\.includeMacros)) { Text(verbatim: localizer.string(SettingsText.exportIncludeMacros)) }
                .settingsAccessibility(SettingsControl.exportIncludeMacros, localizer)
            Text(verbatim: localizer.string(SettingsText.exportMacrosNote)).font(.callout).foregroundStyle(.secondary)
                .padding(.leading, 20)
            Toggle(isOn: option(\.includeAppModes)) {
                Text(verbatim: localizer.string(SettingsText.exportIncludeAppModes))
            }
            .settingsAccessibility(SettingsControl.exportIncludeAppModes, localizer)
            HStack {
                Spacer()
                Button(action: model.cancelExport) { Text(verbatim: localizer.string(SettingsText.exportCancel)) }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(SettingsControl.exportCancel, localizer)
                Button(action: model.saveExport) { Text(verbatim: localizer.string(SettingsText.exportSave)) }
                    .keyboardShortcut(.defaultAction)
                    .settingsAccessibility(SettingsControl.exportSave, localizer)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func option(_ keyPath: WritableKeyPath<ExportSheetState, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.exportSheet?[keyPath: keyPath] ?? true },
            set: { model.exportSheet?[keyPath: keyPath] = $0 })
    }
}

struct ImportSheet: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(SettingsText.importTitle))
            if let error = model.importError { IssueLine(symbol: "exclamationmark.triangle", text: error) }
            if let summary = model.importSummary { ImportSummaryView(model: model, summary: summary) }
            HStack {
                Button(action: model.chooseImportFile) {
                    Text(verbatim: localizer.string(SettingsText.importChooseOther))
                }
                .settingsAccessibility(SettingsControl.importChooseOther, localizer)
                Spacer()
                Button(action: model.cancelImport) { Text(verbatim: localizer.string(SettingsText.importCancel)) }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(SettingsControl.importCancel, localizer)
                Button(action: model.confirmImport) { Text(verbatim: localizer.string(SettingsText.importConfirm)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.importSummary?.isEmptySelection ?? true)
                    .settingsAccessibility(SettingsControl.importConfirm, localizer)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct ImportSummaryView: View {
    @Bindable var model: SettingsWindowModel
    let summary: ImportSummary

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.lines(localizer), id: \.self) {
                Text(verbatim: $0).fixedSize(horizontal: false, vertical: true)
            }
            if summary.hasSettings {
                Toggle(isOn: choice(\.applySettings)) {
                    Text(verbatim: localizer.string(SettingsText.importApplySettings))
                }
                .settingsAccessibility(SettingsControl.importApplySettings, localizer)
            }
            if summary.hasAppModes {
                Toggle(isOn: choice(\.applyAppModes)) {
                    Text(verbatim: localizer.string(SettingsText.importApplyAppModes))
                }
                .settingsAccessibility(SettingsControl.importApplyAppModes, localizer)
            }
            if summary.hasRuleOverrides {
                Toggle(isOn: choice(\.applyRuleOverrides)) {
                    Text(verbatim: localizer.string(SettingsText.importApplyRuleOverrides))
                }
                .settingsAccessibility(SettingsControl.importApplyRuleOverrides, localizer)
            }
            if summary.hasMacros {
                Toggle(isOn: choice(\.applyMacros)) { Text(verbatim: localizer.string(SettingsText.importApplyMacros)) }
                    .settingsAccessibility(SettingsControl.importApplyMacros, localizer)
            }
            if summary.hasDuplicateMacros {
                Picker(selection: duplicates) {
                    Text(verbatim: localizer.string(SettingsText.importKeepMine)).tag(MacroDuplicateResolution.keepMine)
                    Text(verbatim: localizer.string(SettingsText.importUseImported)).tag(
                        MacroDuplicateResolution.useImported)
                } label: {
                    Text(verbatim: localizer.string(SettingsText.importDuplicatesTitle))
                }
                .pickerStyle(.radioGroup)
                .settingsAccessibility(SettingsControl.importDuplicates, localizer)
            }
            Text(verbatim: localizer.string(SettingsText.importBackupNote)).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func choice(_ keyPath: WritableKeyPath<ImportChoices, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.importSummary?.choices[keyPath: keyPath] ?? false },
            set: { model.importSummary?.choices[keyPath: keyPath] = $0 })
    }

    private var duplicates: Binding<MacroDuplicateResolution> {
        Binding(
            get: { model.importSummary?.choices.macroDuplicates ?? .keepMine },
            set: { model.importSummary?.choices.macroDuplicates = $0 })
    }
}
