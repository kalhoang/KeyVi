// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Gõ phím / Typing" (PRD-R24): method Telex/VNI (D1) with a live practice field, tone placement (D2) with hòa and
// hoà side by side, English restore (D4) with its two user lists (ENG-R860); Advanced: lone w (D5), brackets
// (D6), restore-last-word hotkey (D8). The practice field's text stays in memory only (PLT-R901).

import AppModel
import ShellCore
import SwiftUI

struct TypingPaneView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            SettingRow(localizer: localizer, item: .typingMethod) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(selection: Binding(get: { settings.typingMethod }, set: { model.edit(.typingMethod($0)) })) {
                        Text(verbatim: localizer.string(SettingsText.methodTelex)).tag(TypingMethod.telex)
                        Text(verbatim: localizer.string(SettingsText.methodVNI)).tag(TypingMethod.vni)
                    } label: {
                        Text(verbatim: localizer.string(SettingItem.typingMethod.title))
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .settingsAccessibility(SettingsControl.typingMethod, localizer)
                    SettingsPracticeField(drafts: model.drafts, localizer: localizer)
                }
            }
            SettingRow(localizer: localizer, item: .tonePlacement) {
                Picker(selection: Binding(get: { settings.tonePlacement }, set: { model.edit(.tonePlacement($0)) })) {
                    Text(verbatim: localizer.string(SettingsText.toneTraditional)).tag(TonePlacement.traditional)
                    Text(verbatim: localizer.string(SettingsText.toneModern)).tag(TonePlacement.modern)
                } label: {
                    Text(verbatim: localizer.string(SettingItem.tonePlacement.title))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .settingsAccessibility(SettingsControl.tonePlacement, localizer)
            }
            ToggleSetting(
                model: model, item: .englishRestore, control: SettingsControl.englishRestore,
                isOn: settings.englishRestore
            ) {
                .englishRestore($0)
            }
            HStack(alignment: .top, spacing: 16) {
                WordListView(model: model, list: .keepAsTyped)
                WordListView(model: model, list: .keepVietnamese)
            }
            AdvancedSection(model: model, pane: .typing) {
                ToggleSetting(
                    model: model, item: .telexStandaloneW, control: SettingsControl.standaloneW,
                    isOn: settings.telexStandaloneW
                ) { .telexStandaloneW($0) }
                ToggleSetting(
                    model: model, item: .telexBracketKeys, control: SettingsControl.bracketKeys,
                    isOn: settings.telexBracketKeys
                ) { .telexBracketKeys($0) }
                SettingRow(localizer: localizer, item: .restoreHotkey) {
                    HotkeyRecorderView(model: model, role: .restoreLastWord)
                }
            }
            PaneResetButton(model: model, target: .pane(.typing), control: SettingsControl.resetPane)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The live practice field under the method picker. It observes only the drafts, so typing in it does not
/// re-render the pane (ADR 0315).
struct SettingsPracticeField: View {
    @ObservedObject var drafts: SettingsTextDrafts
    let localizer: Localizer

    var body: some View {
        TextField(growing: $drafts.practiceText, placeholder: localizer.string(SettingsText.practicePlaceholder))
            .textFieldStyle(.roundedBorder)
            .reservingLines(2)
            .settingsAccessibility(SettingsControl.practiceField, localizer)
    }
}

/// One ENG-R860 list: entries with a remove button each, and a field to add one.
struct WordListView: View {
    @ObservedObject var model: SettingsWindowModel
    let list: UserWordList

    var body: some View {
        let localizer = model.localizer
        let item: SettingItem = list == .keepAsTyped ? .keepAsTyped : .keepVietnamese
        let entries = list.entries(in: model.settings)
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(localizer: localizer, item: item) {
                Text(verbatim: localizer.string(item.title)).fontWeight(.medium)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        Text(verbatim: localizer.string(SettingsText.listEmpty)).foregroundStyle(.secondary)
                    }
                    ForEach(entries, id: \.self) { word in
                        WordEntryRow(model: model, list: list, word: word)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            WordAddRow(model: model, drafts: model.drafts, list: list)
            if let error = model.wordListError[list] {
                Label {
                    Text(verbatim: error)
                } icon: {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WordEntryRow: View {
    @ObservedObject var model: SettingsWindowModel
    let list: UserWordList
    let word: String

    var body: some View {
        let localizer = model.localizer
        HStack {
            Text(verbatim: word).font(.body.monospaced())
            Spacer()
            Button(action: { model.removeWord(word, from: list) }) {
                Image(systemName: "minus.circle").accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: localizer.format(SettingsText.listRemove, word)))
            .settingsAccessibility(
                SettingsControl.wordRemove, localizer, label: localizer.format(SettingsText.listRemove, word))
        }
    }
}

/// The add field of one list. Its text is in the drafts, which the window model does not publish, so a
/// keystroke re-renders only this row (ADR 0315).
struct WordAddRow: View {
    @ObservedObject var model: SettingsWindowModel
    @ObservedObject var drafts: SettingsTextDrafts
    let list: UserWordList

    var body: some View {
        let localizer = model.localizer
        let draft = Binding(get: { drafts[list] }, set: { drafts[list] = $0 })
        let field = list == .keepAsTyped ? SettingsControl.keepAsTypedField : SettingsControl.keepVietnameseField
        let add = list == .keepAsTyped ? SettingsControl.keepAsTypedAdd : SettingsControl.keepVietnameseAdd
        HStack {
            TextField(text: draft) { Text(verbatim: localizer.string(SettingsText.listPlaceholder)) }
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addWord(to: list) }
                .settingsAccessibility(field, localizer)
            Button(action: { model.addWord(to: list) }) { Text(verbatim: localizer.string(SettingsText.listAdd)) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                .settingsAccessibility(add, localizer)
        }
    }
}
