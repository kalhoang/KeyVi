// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Chung / General" (PRD-R24): open at login (D17), toggle hotkey (D11), remember per app (D12), switch indicator
// (D14), interface language (D18); Advanced: sound on switch (D15), click icon to toggle (D16), layout binding
// (PLT-R373).

import AppModel
import InputHost
import ShellCore
import SwiftUI

struct GeneralPaneView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            OpenAtLoginRow(model: model)
            SettingRow(localizer: model.localizer, item: .toggleHotkey) {
                HotkeyRecorderView(model: model, role: .toggleMode)
            }
            ToggleSetting(
                model: model, item: .rememberPerApp, control: SettingsControl.rememberPerApp,
                isOn: settings.rememberPerApp
            ) {
                .rememberPerApp($0)
            }
            ToggleSetting(
                model: model, item: .switchIndicator, control: SettingsControl.switchIndicator,
                isOn: settings.showSwitchIndicator
            ) { .showSwitchIndicator($0) }
            InterfaceLanguageRow(model: model)
            AdvancedSection(model: model, pane: .general) {
                ToggleSetting(
                    model: model, item: .soundOnSwitch, control: SettingsControl.soundOnSwitch,
                    isOn: settings.soundOnSwitch
                ) {
                    .soundOnSwitch($0)
                }
                ToggleSetting(
                    model: model, item: .clickIconToToggle, control: SettingsControl.clickIconToToggle,
                    isOn: settings.clickIconToToggle
                ) { .clickIconToToggle($0) }
                LayoutBindingSection(model: model)
            }
            PaneResetButton(model: model, target: .pane(.general), control: SettingsControl.resetPane)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// D17 through `SMAppService` (PLT-R205): the toggle reflects the service status. On macOS 12 there is no
/// `SMAppService` (ADR 0315): the toggle is disabled and the note and button lead to System Preferences.
struct OpenAtLoginRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let presentation = model.loginItem
        SettingRow(localizer: localizer, item: .openAtLogin, arguments: [model.appName]) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { presentation.isOn }, set: { model.setOpenAtLogin($0) })) {
                    Text(verbatim: localizer.string(SettingItem.openAtLogin.title))
                }
                .settingsAccessibility(SettingsControl.openAtLogin, localizer)
                .disabled(!presentation.isAvailable)
                if let note = presentation.note {
                    Label {
                        Text(verbatim: model.loginItemNote(note))
                    } icon: {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    }
                    .font(.callout)
                }
                if presentation.offersSystemSettings {
                    Button(action: model.openLoginItemsSettings) {
                        Text(
                            verbatim: localizer.string(
                                presentation.isAvailable
                                    ? SettingsText.openSystemSettings : SettingsText.openSystemPreferences
                            ))
                    }
                    .settingsAccessibility(
                        presentation.isAvailable
                            ? SettingsControl.openSystemSettings : SettingsControl.openSystemPreferences,
                        localizer)
                }
            }
        }
    }
}

struct InterfaceLanguageRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingRow(localizer: localizer, item: .interfaceLanguage) {
            Picker(
                selection: Binding(
                    get: { model.settings.interfaceLanguage }, set: { model.edit(.interfaceLanguage($0)) })
            ) {
                Text(verbatim: localizer.string(SettingsText.languageVietnamese)).tag(InterfaceLanguage.vietnamese)
                Text(verbatim: localizer.string(SettingsText.languageEnglish)).tag(InterfaceLanguage.english)
            } label: {
                Text(verbatim: localizer.string(SettingItem.interfaceLanguage.title))
            }
            .fixedSize()
            .settingsAccessibility(SettingsControl.interfaceLanguage, localizer)
        }
    }
}

/// PLT-R373: off by default; each ASCII-capable layout can be bound to VI or EN.
struct LayoutBindingSection: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let binding = model.layoutBinding
        VStack(alignment: .leading, spacing: 6) {
            ToggleSetting(
                model: model, item: .layoutBinding, control: SettingsControl.layoutBindingEnabled,
                isOn: binding.binding.enabled
            ) { .layoutBinding(binding.settingEnabled($0)) }
            if binding.binding.enabled {
                if binding.rows.isEmpty {
                    Text(verbatim: localizer.string(SettingsText.layoutBindingEmpty)).font(.callout)
                }
                ForEach(binding.rows) { row in
                    LayoutAssignmentRow(model: model, binding: binding, row: row)
                }
                if !binding.isComplete, !binding.rows.isEmpty {
                    Label {
                        Text(verbatim: localizer.string(SettingsText.layoutBindingIncomplete))
                    } icon: {
                        Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    }
                    .font(.callout)
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
        .fixedSize()
        .padding(.leading, 20)
    }
}

/// D11 and D8 recorder (PRD-R15, PRD-R16, PRD-R18). While recording, the window's key events go to the recorder.
struct HotkeyRecorderView: View {
    @ObservedObject var model: SettingsWindowModel
    let role: HotkeyRole
    @FocusState private var focused: Bool

    var body: some View {
        let localizer = model.localizer
        let recording = model.recordingRole == role
        let binding = role == .toggleMode ? model.settings.toggleHotkey : model.settings.restoreHotkey
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(
                    verbatim: localizer.string(
                        role == .toggleMode ? SettingsText.toggleHotkeyTitle : SettingsText.restoreHotkeyTitle))
                Spacer()
                Text(
                    verbatim: recording
                        ? localizer.string(SettingsText.hotkeyRecording)
                        : HotkeyRecorderText.display(binding, localizer: localizer)
                )
                .font(.body.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(
                        recording ? Color.accentColor : .secondary, lineWidth: recording ? 2 : 1))
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
                RecorderShortcutButtons(model: model, role: role)
            }
            RecorderStatusLine(model: model, role: role)
        }
        .onAppear { if recording { focused = true } }
        .onChange(of: recording) { focused = true }
    }
}

/// "Dùng mặc định" for the toggle; "Dùng Escape" and "Không dùng" for the restore key (PRD-R18).
struct RecorderShortcutButtons: View {
    @ObservedObject var model: SettingsWindowModel
    let role: HotkeyRole

    var body: some View {
        let localizer = model.localizer
        if role == .toggleMode {
            Button(action: model.useDefaultToggle) { Text(verbatim: localizer.string(SettingsText.hotkeyUseDefault)) }
                .settingsAccessibility(SettingsControl.toggleHotkeyDefault, localizer)
        } else {
            Button(action: { model.setRestoreHotkey(.key(.escape)) }) {
                Text(verbatim: localizer.string(SettingsText.hotkeyUseEscape))
            }
            .settingsAccessibility(SettingsControl.restoreHotkeyEscape, localizer)
            Button(action: { model.setRestoreHotkey(nil) }) {
                Text(verbatim: localizer.string(SettingsText.hotkeyClear))
            }
            .settingsAccessibility(SettingsControl.restoreHotkeyClear, localizer)
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
                Label {
                    Text(verbatim: status).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: conflict ? "exclamationmark.triangle" : "keyboard").accessibilityHidden(true)
                }
                .font(.callout)
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
