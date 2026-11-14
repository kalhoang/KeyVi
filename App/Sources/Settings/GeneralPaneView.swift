// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Chung / General" (PRD-R24): open at login (D17), toggle hotkey (D11), remember per app (D12), switch indicator
// (D14), interface language (D18); Advanced: sound on switch (D15), click icon to toggle (D16), layout binding
// (PLT-R373). The sections come from `SettingsCatalog.sections(in:)`; this file holds the rows that are more than a
// switch or a menu, and the D11 and D8 recorder shared with the Typing pane.

import AppModel
import InputHost
import ShellCore
import SwiftUI

/// General and Typing: the catalog's grouped sections, the Advanced disclosure and the pane's reset, in a grouped
/// Form (macOS 13 and later) or boxed sections (macOS 12).
struct SettingsSectionsPane: View {
    @ObservedObject var model: SettingsWindowModel
    let pane: SettingsPaneKind

    var body: some View {
        let localizer = model.localizer
        SettingsPaneForm {
            ForEach(SettingsCatalog.sections(in: pane), id: \.self) { section in
                SettingsGroup(header: section.header.map(localizer.string), footer: footer(of: section)) {
                    ForEach(section.rows, id: \.self) { row in SettingsSectionRow(model: model, items: row) }
                }
            }
            if pane.hasAdvancedSection { AdvancedSection(model: model, pane: pane) }
            if let reset = pane.paneReset {
                PaneResetSection(model: model, target: .pane(reset), control: SettingsControl.resetPane)
            }
        }
    }

    /// ENG-R862: under the word lists once a word was learned in an app.
    private func footer(of section: SettingsSection) -> String? {
        guard section.items.contains(.keepAsTyped), model.hasLearnedWords else { return nil }
        return model.localizer.string(SettingsText.listLearnedNote)
    }
}

/// D17 through `SMAppService` (PLT-R205): the switch reflects the service status. On macOS 12 there is no
/// `SMAppService` (ADR 0315): the switch is disabled and the note and button lead to System Preferences.
struct OpenAtLoginRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let presentation = model.loginItem
        let text = model.loginItemText
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(localizer: localizer, item: .openAtLogin, arguments: [model.appName]) {
                Toggle(isOn: Binding(get: { presentation.isOn }, set: { model.setOpenAtLogin($0) })) {
                    Text(verbatim: localizer.string(SettingItem.openAtLogin.title))
                }
                .settingsAccessibility(SettingsControl.openAtLogin, localizer)
                .settingsSwitch()
                .disabled(!presentation.isAvailable)
            }
            if let note = text.note {
                IssueLine(symbol: "exclamationmark.circle", text: note)
            }
            if let button = text.button {
                HStack {
                    Spacer()
                    Button(action: model.openLoginItemsSettings) { Text(verbatim: button) }
                        .settingsAccessibility(
                            presentation.isAvailable
                                ? SettingsControl.openSystemSettings : SettingsControl.openSystemPreferences,
                            localizer, label: button)
                }
            }
        }
    }
}

/// PLT-R373: off by default; each ASCII-capable layout can be bound to VI or EN.
struct LayoutBindingSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let binding = model.layoutBinding
        VStack(alignment: .leading, spacing: 8) {
            ToggleSetting(
                model: model, item: .layoutBinding, control: SettingsControl.layoutBindingEnabled,
                isOn: binding.binding.enabled
            ) { .layoutBinding(binding.settingEnabled($0)) }
            if binding.binding.enabled {
                if binding.rows.isEmpty {
                    IssueLine(symbol: "keyboard", text: localizer.string(SettingsText.layoutBindingEmpty))
                }
                ForEach(binding.rows) { row in
                    LayoutAssignmentRow(model: model, binding: binding, row: row)
                }
                if !binding.isComplete, !binding.rows.isEmpty {
                    IssueLine(
                        symbol: "exclamationmark.circle", text: localizer.string(SettingsText.layoutBindingIncomplete))
                }
            }
        }
    }
}

struct LayoutAssignmentRow: View {
    @ObservedObject var model: SettingsWindowModel
    let binding: LayoutBindingModel
    let row: LayoutBindingModel.Row

    var body: some View {
        let localizer = model.localizer
        SettingsFormRow(title: row.name) {
            Picker(
                selection: Binding(
                    get: { row.assignment }, set: { model.edit(.layoutBinding(binding.assigning($0, to: row.id))) })
            ) {
                ForEach(LayoutBindingModel.Assignment.allCases, id: \.self) { assignment in
                    Text(verbatim: localizer.string(assignment.title)).tag(assignment)
                }
            } label: {
                Text(verbatim: row.name)
            }
            .settingsAccessibility(
                SettingsControl.layoutBindingAssignment, localizer,
                label: localizer.accessibilityLabel(SettingsControl.layoutBindingAssignment) + ": " + row.name
            )
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.leading, 16)
    }
}

/// D11 and D8 recorder (PRD-R15, PRD-R16, PRD-R18): the setting's row with the current keys, then the buttons and
/// the live status. While recording, the window's key events go to the recorder. The restore key also has its
/// on/off switch on the row (D8: Escape by default); its keys and buttons show only while it is on.
struct HotkeyRow: View {
    @ObservedObject var model: SettingsWindowModel
    let item: SettingItem
    let role: HotkeyRole
    @FocusState private var focused: Bool

    var body: some View {
        let recording = model.recordingRole == role
        let binding = role == .toggleMode ? model.settings.toggleHotkey : model.settings.restoreHotkey
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(localizer: model.localizer, item: item) {
                if role == .restoreLastWord {
                    RestoreHotkeySwitch(model: model)
                } else {
                    HotkeyKeysView(model: model, binding: binding, recording: recording)
                }
            }
            if role == .toggleMode || binding != nil || recording {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if role == .restoreLastWord {
                        HotkeyKeysView(model: model, binding: binding, recording: recording)
                    }
                    recorderButton(recording: recording)
                    RecorderShortcutButtons(model: model, role: role)
                }
            }
            RecorderStatusLine(model: model, role: role)
        }
        .onAppear { if recording { focused = true } }
        .onChange(of: recording) { _ in focused = true }
    }

    @ViewBuilder private func recorderButton(recording: Bool) -> some View {
        let localizer = model.localizer
        if recording {
            Button(action: model.cancelRecording) {
                Text(verbatim: localizer.string(SettingsText.hotkeyCancel))
            }
            .focused($focused)
            .settingsAccessibility(
                role == .toggleMode ? SettingsControl.toggleHotkeyCancel : SettingsControl.restoreHotkeyCancel,
                localizer)
        } else {
            Button(action: { model.startRecording(role) }) {
                Text(verbatim: localizer.string(SettingsText.hotkeyChange))
            }
            .focused($focused)
            .settingsAccessibility(
                role == .toggleMode ? SettingsControl.toggleHotkeyChange : SettingsControl.restoreHotkeyChange,
                localizer)
        }
    }
}

/// The recorded keys in a key-cap box; "Nhấn phím..." with an accent border while recording.
struct HotkeyKeysView: View {
    @ObservedObject var model: SettingsWindowModel
    let binding: HotkeyBinding?
    let recording: Bool

    var body: some View {
        let localizer = model.localizer
        Text(
            verbatim: recording
                ? localizer.string(SettingsText.hotkeyRecording)
                : HotkeyRecorderText.display(binding, localizer: localizer)
        )
        .font(.body.monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(
                recording ? Color.accentColor : .clear, lineWidth: 2))
    }
}

/// D8, PRD-R18: the restore key's on/off switch. Off stores an explicit none; on gives Escape back, or keeps the
/// key the user recorded (`RestoreHotkeyToggle`).
struct RestoreHotkeySwitch: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let current = model.settings.restoreHotkey
        Toggle(
            isOn: Binding(
                get: { RestoreHotkeyToggle.isOn(current) },
                set: { on in
                    model.cancelRecording()
                    model.edit(RestoreHotkeyToggle.edit(turningOn: on, current: current))
                })
        ) {
            Text(verbatim: localizer.string(SettingsText.restoreHotkeySwitch))
        }
        .settingsAccessibility(SettingsControl.restoreHotkeySwitch, localizer)
        .settingsSwitch()
    }
}

/// "Dùng mặc định" for the toggle; "Dùng Escape" for the restore key, whose off switch is `RestoreHotkeySwitch`
/// (PRD-R18).
struct RecorderShortcutButtons: View {
    @ObservedObject var model: SettingsWindowModel
    let role: HotkeyRole

    var body: some View {
        let localizer = model.localizer
        if role == .toggleMode {
            Button(action: model.useDefaultToggle) { Text(verbatim: localizer.string(SettingsText.hotkeyUseDefault)) }
                .settingsAccessibility(SettingsControl.toggleHotkeyDefault, localizer)
        } else {
            Button(action: { model.setRestoreHotkey(RestoreHotkeyToggle.defaultBinding) }) {
                Text(verbatim: localizer.string(SettingsText.hotkeyUseEscape))
            }
            .settingsAccessibility(SettingsControl.restoreHotkeyEscape, localizer)
        }
    }
}

/// Live keys, the rejection reason, or the PRD-R16 warning with its help link (a symbol, not only colour).
struct RecorderStatusLine: View {
    @ObservedObject var model: SettingsWindowModel
    let role: HotkeyRole

    var body: some View {
        let localizer = model.localizer
        if let status = model.recorderStatus(for: role) {
            let conflict = model.hasConflict(for: role)
            VStack(alignment: .leading, spacing: 4) {
                IssueLine(symbol: conflict ? "exclamationmark.triangle" : "keyboard", text: status)
                if conflict, let url = model.conflictHelpURL {
                    Button(action: { model.open(url) }) {
                        Text(verbatim: localizer.string(SettingsText.hotkeyConflictHelp))
                    }
                    .buttonStyle(.link)
                    .settingsAccessibility(SettingsControl.hotkeyConflictHelp, localizer)
                }
            }
        }
    }
}
