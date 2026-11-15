// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Kiểu gõ / Typing" (PRD-R24): method Telex/VNI (D1) with a live practice field, tone placement (D2) with hòa and
// hoà side by side, English restore (D4) with its two user lists (ENG-R860), each learned entry with the app it was
// learned in, a remove and a "use in every app" button (ENG-R862), then D28 with "Xem từ đã học..." (PRD-R78,
// LearnedChoicesSheet.swift); Advanced: lone w (D5), brackets (D6), restore-last-word hotkey (D8), D29. The pane is
// `SettingsSectionsPane(pane: .typing)`; this file holds the practice field and the word lists. The practice field's
// text stays in memory only (PLT-R901).

import AppModel
import SettingsStore
import ShellCore
import SwiftUI

/// The live practice field under the method picker. It observes only the drafts, so typing in it does not
/// re-render the pane (ADR 0315).
struct SettingsPracticeField: View {
    @ObservedObject var drafts: SettingsTextDrafts
    let localizer: Localizer

    var body: some View {
        TextField(
            settingsText: $drafts.practiceText, prompt: localizer.string(SettingsText.practicePlaceholder),
            growing: true
        )
        .settingsAccessibility(SettingsControl.practiceField, localizer)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .reservingLines(2)
    }
}

/// One ENG-R860 list: its title and explanation, the entries in a rounded list box with a remove button each (learned
/// ones also show their app and can be made global, ENG-R862), and a field to add one.
struct WordListView: View {
    @ObservedObject var model: SettingsWindowModel
    let list: UserWordList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WordListLabel(localizer: model.localizer, list: list)
            WordListBox(model: model, list: list)
            WordListAddArea(model: model, list: list)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The two lists side by side, part by part, so their boxes and fields line up even when one explanation wraps to
/// more lines than the other.
struct WordListsPair: View {
    @ObservedObject var model: SettingsWindowModel
    let lists: [UserWordList]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: SettingsMetrics.rowSpacing) {
                ForEach(lists, id: \.self) { list in WordListLabel(localizer: model.localizer, list: list) }
            }
            HStack(alignment: .top, spacing: SettingsMetrics.rowSpacing) {
                ForEach(lists, id: \.self) { list in WordListBox(model: model, list: list) }
            }
            HStack(alignment: .top, spacing: SettingsMetrics.rowSpacing) {
                ForEach(lists, id: \.self) { list in WordListAddArea(model: model, list: list) }
            }
        }
    }
}

struct WordListLabel: View {
    let localizer: Localizer
    let list: UserWordList

    var body: some View {
        let item = list.settingItem
        RowLabel(title: localizer.string(item.title), explanation: localizer.string(item.explanation))
    }
}

struct WordListBox: View {
    @ObservedObject var model: SettingsWindowModel
    let list: UserWordList

    var body: some View {
        let rows = model.wordRows(list)
        ListBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(verbatim: model.localizer.string(SettingsText.listEmpty))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    ForEach(rows) { row in
                        Group {
                            if let learned = row.learned {
                                LearnedWordRow(model: model, word: learned)
                            } else {
                                WordEntryRow(model: model, list: list, word: row.word)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }
            .frame(height: SettingsMetrics.wordListHeight)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity)
    }
}

/// The add field of a list and the reason an entry was refused.
struct WordListAddArea: View {
    @ObservedObject var model: SettingsWindowModel
    let list: UserWordList

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WordAddRow(model: model, drafts: model.drafts, list: list)
            if let error = model.wordListError[list] {
                IssueLine(symbol: "exclamationmark.circle", text: error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension UserWordList {
    /// The catalog setting that names and explains the list (PRD-R25).
    var settingItem: SettingItem { self == .keepAsTyped ? .keepAsTyped : .keepVietnamese }
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

/// A word learned in one app (ENG-R862): the word, the app's name (resolved now, never stored), "use in every app"
/// and remove.
struct LearnedWordRow: View {
    @ObservedObject var model: SettingsWindowModel
    let word: LearnedWord

    var body: some View {
        let localizer = model.localizer
        let scope = localizer.format(SettingsText.listLearnedIn, model.appName(for: word.app))
        let makeGlobal = localizer.format(SettingsText.listMakeGlobal, word.raw)
        let remove = localizer.format(SettingsText.listRemove, word.raw)
        HStack(spacing: 6) {
            Text(verbatim: word.raw).font(.body.monospaced())
            Text(verbatim: scope).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: { model.makeLearnedWordGlobal(word) }) {
                Image(systemName: "globe").accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: makeGlobal))
            .settingsAccessibility(SettingsControl.wordMakeGlobal, localizer, label: makeGlobal + ", " + scope)
            Button(action: { model.forgetLearnedWord(word) }) {
                Image(systemName: "minus.circle").accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: remove))
            .settingsAccessibility(SettingsControl.wordRemove, localizer, label: remove + ", " + scope)
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
            TextField(settingsText: draft, prompt: localizer.string(SettingsText.listPlaceholder))
                .settingsAccessibility(field, localizer)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { model.addWord(to: list) }
            Button(action: { model.addWord(to: list) }) { Text(verbatim: localizer.string(SettingsText.listAdd)) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                .settingsAccessibility(add, localizer)
        }
    }
}
