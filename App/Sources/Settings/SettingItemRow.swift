// SPDX-License-Identifier: GPL-3.0-or-later
//
// One row per setting of `SettingsCatalog` (PRD-R24, PRD-R25): the grouped sections and the Advanced disclosures
// draw their settings through this switch, so a setting looks the same wherever it appears. Switches for Bool
// settings, pop-up menus for choices, segmented controls where the spec shows both values side by side (D1, D2).

import AppModel
import SettingsStore
import ShellCore
import SwiftUI

struct SettingItemRow: View {
    @ObservedObject var model: SettingsWindowModel
    let item: SettingItem

    var body: some View {
        let settings = model.settings
        switch item {
        case .openAtLogin: OpenAtLoginRow(model: model)
        case .toggleHotkey: HotkeyRow(model: model, item: item, role: .toggleMode)
        case .rememberPerApp:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.rememberPerApp, isOn: settings.rememberPerApp
            ) { .rememberPerApp($0) }
        case .switchIndicator:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.switchIndicator, isOn: settings.showSwitchIndicator
            ) { .showSwitchIndicator($0) }
        case .interfaceLanguage: InterfaceLanguageRow(model: model)
        case .soundOnSwitch:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.soundOnSwitch, isOn: settings.soundOnSwitch
            ) { .soundOnSwitch($0) }
        case .clickIconToToggle:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.clickIconToToggle, isOn: settings.clickIconToToggle
            ) { .clickIconToToggle($0) }
        case .layoutBinding: LayoutBindingSection(model: model)
        case .typingMethod: TypingMethodRow(model: model)
        case .tonePlacement: TonePlacementRow(model: model)
        case .englishRestore:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.englishRestore, isOn: settings.englishRestore
            ) { .englishRestore($0) }
        case .keepAsTyped: WordListView(model: model, list: .keepAsTyped)
        case .keepVietnamese: WordListView(model: model, list: .keepVietnamese)
        case .neverCorrect: WordListView(model: model, list: .neverCorrect)
        case .learnCollisionChoices: LearnCollisionChoicesRow(model: model)
        case .typoCorrection:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.typoCorrection, isOn: settings.typoCorrection
            ) { .typoCorrection($0) }
        case .telexStandaloneW:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.standaloneW, isOn: settings.telexStandaloneW
            ) { .telexStandaloneW($0) }
        case .telexBracketKeys:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.bracketKeys, isOn: settings.telexBracketKeys
            ) { .telexBracketKeys($0) }
        case .restoreHotkey: HotkeyRow(model: model, item: item, role: .restoreLastWord)
        case .lookaheadRevision:
            ToggleSetting(
                model: model, item: item, control: SettingsControl.lookaheadRevision, isOn: settings.lookaheadRevision
            ) { .lookaheadRevision($0) }
        case .macrosEnabled:
            ToggleSetting(model: model, item: item, control: MacrosControl.enabled, isOn: settings.macrosEnabled) {
                .macrosEnabled($0)
            }
        case .updateChannel: UpdateChannelRow(model: model)
        case .automaticallyCheckForUpdates:
            ToggleSetting(
                model: model, item: item, control: SupportControl.autoCheck,
                isOn: settings.automaticallyCheckForUpdates
            ) { .automaticallyCheckForUpdates($0) }
        case .automaticallyInstallUpdates:
            ToggleSetting(
                model: model, item: item, control: SupportControl.autoInstall,
                isOn: settings.automaticallyInstallUpdates
            ) { .automaticallyInstallUpdates($0) }
        }
    }
}

/// A row of `SettingSection.rows`: one setting, or the two ENG-R860 word lists side by side (the never-correct list,
/// PRD-R81, is a row of its own under them).
struct SettingsSectionRow: View {
    @ObservedObject var model: SettingsWindowModel
    let items: [SettingItem]

    var body: some View {
        if items == [.keepAsTyped, .keepVietnamese] {
            WordListsPair(model: model, lists: [.keepAsTyped, .keepVietnamese])
        } else {
            ForEach(items, id: \.self) { item in SettingItemRow(model: model, item: item) }
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
            .settingsAccessibility(SettingsControl.interfaceLanguage, localizer)
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

/// D1 with the live practice field under the row (the field's text stays in memory only, PLT-R901).
struct TypingMethodRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(localizer: localizer, item: .typingMethod) {
                Picker(
                    selection: Binding(get: { model.settings.typingMethod }, set: { model.edit(.typingMethod($0)) })
                ) {
                    Text(verbatim: localizer.string(SettingsText.methodTelex)).tag(TypingMethod.telex)
                    Text(verbatim: localizer.string(SettingsText.methodVNI)).tag(TypingMethod.vni)
                } label: {
                    Text(verbatim: localizer.string(SettingItem.typingMethod.title))
                }
                .settingsAccessibility(SettingsControl.typingMethod, localizer)
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            SettingsPracticeField(drafts: model.drafts, localizer: localizer)
        }
    }
}

/// D2: `hòa` and `hoà` side by side (PRD-R24).
struct TonePlacementRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingRow(localizer: localizer, item: .tonePlacement) {
            Picker(selection: Binding(get: { model.settings.tonePlacement }, set: { model.edit(.tonePlacement($0)) })) {
                Text(verbatim: localizer.string(SettingsText.toneTraditional)).tag(TonePlacement.traditional)
                Text(verbatim: localizer.string(SettingsText.toneModern)).tag(TonePlacement.modern)
            } label: {
                Text(verbatim: localizer.string(SettingItem.tonePlacement.title))
            }
            .settingsAccessibility(SettingsControl.tonePlacement, localizer)
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// D21 with the PRD-R53 note after leaving Beta.
struct UpdateChannelRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(localizer: localizer, item: .updateChannel) {
                Picker(
                    selection: Binding(get: { model.settings.updateChannel }, set: { model.selectChannel($0) })
                ) {
                    Text(verbatim: localizer.string(SupportText.channelStable)).tag(UpdateChannel.stable)
                    Text(verbatim: localizer.string(SupportText.channelBeta)).tag(UpdateChannel.beta)
                } label: {
                    Text(verbatim: localizer.string(SupportText.channelTitle))
                }
                .settingsAccessibility(SupportControl.channel, localizer)
                .pickerStyle(.menu)
                .labelsHidden()
            }
            if let note = model.channelNote.text(appName: model.appName, localizer: localizer) {
                IssueLine(symbol: SettingsSymbol.info, text: note)
            }
        }
    }
}
