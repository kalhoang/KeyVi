// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Viết tắt / Macros" (PRD-R29-R33): the D9 switch, search, sort, add, import and export, a list with an enable
// checkbox per macro, edit, duplicate, delete and enable or disable all. The list scrolls (PRD-R24 acceptance).
// Rows with a problem show a symbol and the reason (row context).

import AppModel
import Foundation
import SettingsStore
import ShellCore
import SwiftUI

struct MacrosPaneView: View {
    @ObservedObject var model: SettingsWindowModel
    @State private var selection: UUID?

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard { SettingItemRow(model: model, item: .macrosEnabled) }
            MacrosToolbar(model: model)
            ListBox {
                if model.macroList.isEmpty {
                    MacrosEmptyState(model: model)
                } else if model.macroList.visible.isEmpty {
                    Text(verbatim: localizer.format(MacrosText.noResults, model.macroList.searchText))
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    MacrosTable(model: model, selection: $selection)
                }
            }
            MacrosFooter(model: model, selection: $selection)
            HStack {
                Spacer()
                PaneResetButton(model: model, target: .pane(.macros), control: MacrosControl.resetPane)
            }
        }
        .padding(.horizontal, SettingsMetrics.listPaneInset)
        .padding(.vertical, SettingsMetrics.paneInset)
    }
}

/// Search and sort above the list; add, import and export under it (`MacrosFooter`).
struct MacrosToolbar: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        let localizer = model.localizer
        HStack(spacing: 8) {
            TextField(settingsText: $model.macroList.searchText, prompt: localizer.string(MacrosText.searchPlaceholder))
                .settingsAccessibility(MacrosControl.search, localizer)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Picker(selection: $model.macroList.sort) {
                ForEach(MacroSortOrder.allCases, id: \.self) { order in
                    Text(verbatim: localizer.string(order.title)).tag(order)
                }
            } label: {
                Text(verbatim: localizer.string(MacrosText.sortTitle))
            }
            .settingsAccessibility(MacrosControl.sort, localizer)
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// PRD-R43: "Chưa có mục viết tắt nào..." with "Thêm viết tắt" and "Nhập từ file..." (both buttons are under the list).
struct MacrosEmptyState: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        Text(verbatim: model.localizer.string(MacrosText.empty))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MacrosTable: View {
    @ObservedObject var model: SettingsWindowModel
    @Binding var selection: UUID?

    var body: some View {
        let localizer = model.localizer
        let issues = model.macroIssues
        Table(model.macroList.visible, selection: $selection) {
            TableColumn(localizer.string(MacrosText.columnEnabled)) { macro in
                Toggle(isOn: Binding(get: { macro.enabled }, set: { model.setMacroEnabled($0, id: macro.id) })) {
                    Text(verbatim: macro.trigger)
                }
                .labelsHidden()
                .settingsAccessibility(
                    MacrosControl.rowEnabled, localizer,
                    label: localizer.accessibilityLabel(MacrosControl.rowEnabled) + ": " + macro.trigger)
            }
            .width(40)
            TableColumn(localizer.string(MacrosText.columnShortcut)) { macro in
                MacroShortcutCell(localizer: localizer, macro: macro, issue: issues[macro.id])
            }
            .width(min: 90, ideal: 120)
            TableColumn(localizer.string(MacrosText.columnExpansion)) { macro in
                Text(verbatim: macro.expansion.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .settingsAccessibility(MacrosControl.list, localizer)
        .rowMenu(model: model)
    }
}

extension View {
    /// Row context menu and double-click to edit, from macOS 13 (`contextMenu(forSelectionType:)`). On macOS 12
    /// the footer shows the same actions for the selected row (ADR 0315).
    @ViewBuilder
    fileprivate func rowMenu(model: SettingsWindowModel) -> some View {
        if #available(macOS 13, *) {
            contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first { MacroRowMenu(model: model, id: id) }
            } primaryAction: { ids in
                if let id = ids.first { model.editMacro(id) }
            }
        } else {
            self
        }
    }
}

struct MacroShortcutCell: View {
    let localizer: Localizer
    let macro: StoredMacro
    let issue: MacroRowIssue?

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: macro.trigger).font(.body.monospaced())
            if let issue {
                let reason = MacroIssueText.text(issue, shortcut: macro.trigger, localizer: localizer)
                Image(systemName: "exclamationmark.triangle")
                    .help(Text(verbatim: reason))
                    .accessibilityLabel(Text(verbatim: reason))
            }
        }
    }
}

struct MacroRowMenu: View {
    @ObservedObject var model: SettingsWindowModel
    let id: UUID

    var body: some View {
        let localizer = model.localizer
        Button(action: { model.editMacro(id) }) { Text(verbatim: localizer.string(MacrosText.edit)) }
            .settingsAccessibility(MacrosControl.rowEdit, localizer)
        Button(action: { model.duplicateMacro(id) }) { Text(verbatim: localizer.string(MacrosText.duplicate)) }
            .settingsAccessibility(MacrosControl.rowDuplicate, localizer)
        Button(action: { model.macroToDelete = model.macroList.macros.first { $0.id == id } }) {
            Text(verbatim: localizer.string(MacrosText.delete))
        }
        .settingsAccessibility(MacrosControl.rowDelete, localizer)
    }
}

/// Under the list: add, import, export and the count; then the selected macro's actions (keyboard users select with
/// the arrow keys, then Tab to these) and the bulk switches.
struct MacrosFooter: View {
    @ObservedObject var model: SettingsWindowModel
    @Binding var selection: UUID?

    var body: some View {
        let localizer = model.localizer
        let list = model.macroList
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: model.addMacro) { Text(verbatim: localizer.string(MacrosText.add)) }
                    .settingsAccessibility(MacrosControl.add, localizer)
                Button(action: model.chooseMacroFile) { Text(verbatim: localizer.string(MacrosText.importFile)) }
                    .settingsAccessibility(MacrosControl.importFile, localizer)
                Button(action: model.exportMacros) { Text(verbatim: localizer.string(MacrosText.exportFile)) }
                    .disabled(list.isEmpty)
                    .settingsAccessibility(MacrosControl.exportFile, localizer)
                Spacer(minLength: 8)
                Text(verbatim: localizer.format(MacrosText.count, list.macros.count)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let id = selection, list.macros.contains(where: { $0.id == id }) {
                    MacroRowMenu(model: model, id: id)
                }
                Spacer(minLength: 8)
                Button(action: { model.setAllMacrosEnabled(true) }) {
                    Text(verbatim: localizer.string(MacrosText.enableAll))
                }
                .disabled(list.isEmpty || list.allEnabled)
                .settingsAccessibility(MacrosControl.enableAll, localizer)
                Button(action: { model.setAllMacrosEnabled(false) }) {
                    Text(verbatim: localizer.string(MacrosText.disableAll))
                }
                .disabled(list.isEmpty || list.allDisabled)
                .settingsAccessibility(MacrosControl.disableAll, localizer)
            }
        }
    }
}

/// PRD-R31 delete with confirmation.
struct MacroDeleteAlert: ViewModifier {
    @ObservedObject var model: SettingsWindowModel

    func body(content: Content) -> some View {
        let localizer = model.localizer
        content.alert(
            Text(verbatim: localizer.format(MacrosText.deleteTitle, model.macroToDelete?.trigger ?? "")),
            isPresented: Binding(get: { model.macroToDelete != nil }, set: { if !$0 { model.macroToDelete = nil } })
        ) {
            Button(role: .cancel, action: { model.macroToDelete = nil }) {
                Text(verbatim: localizer.string(MacrosText.deleteCancel))
            }
            .settingsAccessibility(MacrosControl.deleteCancel, localizer)
            Button(role: .destructive, action: model.confirmDeleteMacro) {
                Text(verbatim: localizer.string(MacrosText.deleteConfirm))
            }
            .settingsAccessibility(MacrosControl.deleteConfirm, localizer)
        }
    }
}
