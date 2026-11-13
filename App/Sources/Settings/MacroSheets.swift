// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Macro editor sheet (PRD-R29-R31: live validation with the PRD-R29 reasons, Telex digit advice, NFC on save)
// and the import preview sheet (PRD-R32: counts of new, duplicate and invalid rows and the duplicate choice).

import AppModel
import SettingsStore
import ShellCore
import SwiftUI

struct MacroEditorSheet: View {
    let model: SettingsWindowModel
    @State private var draft = MacroDraft()

    var body: some View {
        let localizer = model.localizer
        let check = model.draftCheck(draft)
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(
                text: localizer.string(draft.id == nil ? MacrosText.editorTitleAdd : MacrosText.editorTitleEdit))
            Text(verbatim: localizer.string(MacrosText.editorShortcut)).fontWeight(.medium)
            TextField(text: $draft.shortcut) { Text(verbatim: localizer.string(MacrosText.editorShortcut)) }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .settingsAccessibility(MacrosControl.editorShortcut, localizer)
            Text(verbatim: localizer.string(MacrosText.editorShortcutHelp)).font(.callout).foregroundStyle(.secondary)
            Text(verbatim: localizer.string(MacrosText.editorExpansion)).fontWeight(.medium)
            TextEditor(text: $draft.expansion)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .settingsAccessibility(MacrosControl.editorExpansion, localizer)
            Text(verbatim: localizer.string(MacrosText.editorExpansionHelp)).font(.callout).foregroundStyle(.secondary)
            MacroEditorOptions(localizer: localizer, draft: $draft)
            MacroCheckLines(model: model, draft: draft, check: check)
            HStack {
                Spacer()
                Button(action: { model.macroDraft = nil }) { Text(verbatim: localizer.string(MacrosText.editorCancel)) }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(MacrosControl.editorCancel, localizer)
                Button(action: { model.saveMacroDraft(draft) }) {
                    Text(verbatim: localizer.string(MacrosText.editorSave))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!check.canSave)
                .settingsAccessibility(MacrosControl.editorSave, localizer)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { draft = model.macroDraft ?? MacroDraft() }
    }
}

struct MacroEditorOptions: View {
    let localizer: Localizer
    @Binding var draft: MacroDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $draft.adaptCase) { Text(verbatim: localizer.string(MacrosText.editorAdaptCase)) }
                .settingsAccessibility(MacrosControl.editorAdaptCase, localizer)
            Text(verbatim: localizer.string(MacrosText.editorAdaptCaseHelp)).font(.callout).foregroundStyle(.secondary)
            Toggle(isOn: $draft.enabled) { Text(verbatim: localizer.string(MacrosText.editorEnabled)) }
                .settingsAccessibility(MacrosControl.editorEnabled, localizer)
        }
    }
}

/// The blocking reason (after the user typed something), advice, and a save error from the engine check.
struct MacroCheckLines: View {
    let model: SettingsWindowModel
    let draft: MacroDraft
    let check: MacroDraftCheck

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 4) {
            if let issue = check.issue, !draft.shortcut.isEmpty || !draft.expansion.isEmpty {
                IssueLine(
                    symbol: "exclamationmark.triangle",
                    text: MacroIssueText.text(issue, shortcut: draft.shortcut, localizer: localizer))
            }
            ForEach(check.warnings, id: \.self) { warning in
                IssueLine(symbol: "info.circle", text: MacroIssueText.warningText(warning, localizer: localizer))
            }
            if let error = model.macroDraftError { IssueLine(symbol: "exclamationmark.octagon", text: error) }
        }
    }
}

/// A message with a symbol, so its kind does not depend on colour (PRD-R67).
struct IssueLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.callout)
    }
}

struct MacroImportSheet: View {
    @Bindable var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            PaneHeading(text: localizer.string(MacrosText.importTitle))
            if let error = model.macroImportError { IssueLine(symbol: "exclamationmark.triangle", text: error) }
            if let session = model.macroImport { MacroImportPreviewView(model: model, session: session) }
            HStack {
                Button(action: model.chooseMacroFile) { Text(verbatim: localizer.string(MacrosText.importChooseOther)) }
                    .settingsAccessibility(MacrosControl.importChooseOther, localizer)
                Spacer()
                Button(action: closeSheet) { Text(verbatim: localizer.string(MacrosText.importCancel)) }
                    .keyboardShortcut(.cancelAction)
                    .settingsAccessibility(MacrosControl.importCancel, localizer)
                Button(action: model.confirmMacroImport) { Text(verbatim: localizer.string(MacrosText.importConfirm)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.macroImport == nil)
                    .settingsAccessibility(MacrosControl.importConfirm, localizer)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func closeSheet() {
        model.macroImport = nil
        model.macroImportError = nil
    }
}

struct MacroImportPreviewView: View {
    @Bindable var model: SettingsWindowModel
    let session: MacroImportSession

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localizer.format(MacrosText.importNew, session.newCount))
            Text(verbatim: localizer.format(MacrosText.importDuplicates, session.duplicateCount))
            Text(verbatim: localizer.format(MacrosText.importInvalid, session.invalidCount))
            if session.invalidCount > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.invalidLines(localizer), id: \.self) { Text(verbatim: $0).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if session.duplicateCount > 0 {
                Picker(selection: resolution) {
                    Text(verbatim: localizer.string(MacrosText.importKeepMine)).tag(MacroDuplicateResolution.keepMine)
                    Text(verbatim: localizer.string(MacrosText.importUseImported)).tag(
                        MacroDuplicateResolution.useImported)
                } label: {
                    Text(verbatim: localizer.string(MacrosText.importDuplicateChoice))
                }
                .pickerStyle(.radioGroup)
                .settingsAccessibility(MacrosControl.importDuplicateChoice, localizer)
            }
        }
    }

    private var resolution: Binding<MacroDuplicateResolution> {
        Binding(
            get: { model.macroImport?.resolution ?? .keepMine },
            set: { model.macroImport?.resolution = $0 })
    }
}
