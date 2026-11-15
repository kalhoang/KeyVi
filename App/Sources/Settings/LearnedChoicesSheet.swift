// SPDX-License-Identifier: GPL-3.0-or-later
//
// D28 in the Typing pane and its learned-words sheet (PRD-R78, PRD-R79; decision of the product owner, 15/11/2026:
// collision choices are learned per user across all apps, from corrections and silent acceptance). The row is the
// title and explanation with the switch and "Xem từ đã học..." under it in the control column; the button stays
// available with the switch off, since turning D28 off keeps the learned words until "Xóa tất cả". The sheet lists the
// entries that vote for a side as word, arrow, result and context (`LearnedChoicesSheetState`), each with a remove
// button (VoiceOver label and hint, PRD-R66); from macOS 13 a row also has a context menu with the same command,
// macOS 12 keeps the buttons only (PRD-R8, ADR 0315). The words are bundled vocabulary and are never logged
// (PLT-R901).

import AppModel
import SettingsStore
import ShellCore
import SwiftUI

/// D28: the switch with the button that opens the sheet under it, in the row's control column, beside the title and
/// its explanation with the app name (PRD-R25). In the control column the button adds no line of its own, which keeps
/// the Typing pane as short as the design allows (PRD-R24 acceptance: no scrolling on a 13-inch display).
struct LearnCollisionChoicesRow: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        SettingRow(localizer: localizer, item: .learnCollisionChoices, arguments: [model.appName]) {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(
                    isOn: Binding(
                        get: { model.settings.learnCollisionChoices }, set: { model.edit(.learnCollisionChoices($0)) })
                ) {
                    Text(verbatim: localizer.string(SettingItem.learnCollisionChoices.title))
                }
                .settingsAccessibility(SettingsControl.learnCollisionChoices, localizer)
                .settingsSwitch()
                Button(action: model.showLearnedChoices) {
                    Text(verbatim: localizer.string(SettingsText.learnedChoicesShow))
                }
                .controlSize(.small)
                .settingsAccessibility(SettingsControl.learnedChoicesShow, localizer)
            }
        }
    }
}

/// The sheet: heading, one line on scope, the list or its empty state, then "Xóa tất cả..." and "Xong".
struct LearnedChoicesSheet: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        let sheet = model.learnedChoices
        VStack(alignment: .leading, spacing: 12) {
            PaneHeading(text: localizer.string(SettingsText.learnedChoicesTitle))
            Text(verbatim: localizer.string(SettingsText.learnedChoicesIntro))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ListBox {
                if let sheet, !sheet.isEmpty {
                    LearnedChoicesList(model: model, rows: sheet.rows)
                } else {
                    Text(
                        verbatim: LearnedChoicesSheetState.emptyText(
                            appName: model.appName, restoreHotkey: model.settings.restoreHotkey, localizer)
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 240)
            HStack {
                Button(action: model.requestClearLearnedChoices) {
                    Text(verbatim: localizer.string(SettingsText.learnedChoicesRemoveAll))
                }
                .settingsAccessibility(SettingsControl.learnedChoicesRemoveAll, localizer)
                Spacer()
                Button(action: model.closeLearnedChoices) {
                    Text(verbatim: localizer.string(SettingsText.learnedChoicesDone))
                }
                .keyboardShortcut(.defaultAction)
                .settingsAccessibility(SettingsControl.learnedChoicesDone, localizer)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand(perform: model.closeLearnedChoices)
        .modifier(ClearLearnedChoicesAlert(model: model))
    }
}

/// The rows in a list with selection, so macOS 13 and later can offer a row context menu.
struct LearnedChoicesList: View {
    @ObservedObject var model: SettingsWindowModel
    let rows: [LearnedChoiceRow]
    @State private var selection: CollisionMemoryKey?

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in LearnedChoiceRowView(model: model, row: row).tag(row.id) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .learnedChoiceRowMenu(model: model, rows: rows)
    }
}

extension View {
    /// Row context menu from macOS 13 (`contextMenu(forSelectionType:)`); on macOS 12 the row's own remove button
    /// is the command (PRD-R8, ADR 0315).
    @ViewBuilder
    fileprivate func learnedChoiceRowMenu(model: SettingsWindowModel, rows: [LearnedChoiceRow]) -> some View {
        if #available(macOS 13, *) {
            contextMenu(forSelectionType: CollisionMemoryKey.self) { keys in
                if let key = keys.first, let row = rows.first(where: { $0.id == key }) {
                    LearnedChoiceRowMenu(model: model, row: row)
                }
            }
        } else {
            self
        }
    }
}

struct LearnedChoiceRowMenu: View {
    @ObservedObject var model: SettingsWindowModel
    let row: LearnedChoiceRow

    var body: some View {
        let localizer = model.localizer
        Button(action: { model.forgetLearnedChoice(row) }) { Text(verbatim: row.removeLabel(localizer)) }
            .settingsAccessibility(SettingsControl.learnedChoiceRemove, localizer, label: row.removeLabel(localizer))
    }
}

/// `as -> á` and the context in words; VoiceOver reads the row as one sentence, then its remove button.
struct LearnedChoiceRowView: View {
    @ObservedObject var model: SettingsWindowModel
    let row: LearnedChoiceRow

    var body: some View {
        let localizer = model.localizer
        let remove = row.removeLabel(localizer)
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: row.word).font(.body.monospaced())
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(verbatim: row.result)
                Spacer(minLength: 8)
                Text(verbatim: row.contextText(localizer)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: row.accessibilityText(localizer)))
            Button(action: { model.forgetLearnedChoice(row) }) {
                Image(systemName: "minus.circle").accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: remove))
            .settingsAccessibility(SettingsControl.learnedChoiceRemove, localizer, label: remove)
        }
        .padding(.vertical, 2)
    }
}

/// "Xóa tất cả" asks first (PRD-R78): every entry goes, acceptance counters included, and the file is deleted.
struct ClearLearnedChoicesAlert: ViewModifier {
    @ObservedObject var model: SettingsWindowModel

    func body(content: Content) -> some View {
        let localizer = model.localizer
        content.alert(
            Text(verbatim: localizer.string(SettingsText.learnedClearTitle)),
            isPresented: Binding(
                get: { model.learnedChoices?.confirmsClearAll ?? false },
                set: { if !$0 { model.cancelClearLearnedChoices() } })
        ) {
            Button(role: .cancel, action: model.cancelClearLearnedChoices) {
                Text(verbatim: localizer.string(SettingsText.learnedClearCancel))
            }
            .settingsAccessibility(SettingsControl.learnedClearCancel, localizer)
            Button(role: .destructive, action: model.confirmClearLearnedChoices) {
                Text(verbatim: localizer.string(SettingsText.learnedClearConfirm))
            }
            .settingsAccessibility(SettingsControl.learnedClearConfirm, localizer)
        } message: {
            Text(verbatim: localizer.format(SettingsText.learnedClearBody, model.appName))
        }
    }
}
