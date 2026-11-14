// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Ứng dụng / Apps" (PRD-R34-R38): apps typed in (most recent first) and apps with rules, with icon and name,
// rule, remembered mode and compatibility status (symbol plus text, never colour alone, PRD-R67), in a rounded list.
// The selected row's details sheet and "Báo lỗi với ứng dụng này..." (PRD-R37) are under the list and, from macOS
// 13, in the row's context menu. The list scrolls (PRD-R24 acceptance).

import AppKit
import AppModel
import CompatRules
import ShellCore
import SwiftUI

struct AppsPaneView: View {
    @ObservedObject var model: SettingsWindowModel
    @State private var selection: BundleKey?

    var body: some View {
        let localizer = model.localizer
        let rows = model.appRows
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: localizer.string(AppsText.explanation))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                ListBox {
                    Text(verbatim: localizer.string(AppsText.empty))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ListBox { AppsTable(model: model, rows: rows, selection: $selection) }
            }
            HStack(spacing: 8) {
                AppSelectionActions(model: model, row: rows.first { $0.bundle == selection })
                Spacer(minLength: 8)
                PaneResetButton(model: model, target: .pane(.apps), control: AppsControl.resetPane)
            }
        }
        .padding(.horizontal, SettingsMetrics.listPaneInset)
        .padding(.vertical, SettingsMetrics.paneInset)
    }
}

struct AppsTable: View {
    @ObservedObject var model: SettingsWindowModel
    let rows: [AppsPaneRow]
    @Binding var selection: BundleKey?

    var body: some View {
        let localizer = model.localizer
        Table(rows, selection: $selection) {
            TableColumn(localizer.string(AppsText.columnApp)) { row in AppNameCell(model: model, row: row) }
                .width(min: 80, ideal: 92)
            TableColumn(localizer.string(AppsText.columnRule)) { row in RulePicker(model: model, row: row) }
                .width(118)
            TableColumn(localizer.string(AppsText.columnRemembered)) { row in
                Text(verbatim: localizer.string(row.rememberedModeTitle))
            }
            .width(76)
            TableColumn(localizer.string(AppsText.columnStatus)) { row in
                StatusCell(localizer: localizer, status: row.status)
            }
            .width(min: 140, ideal: 140, max: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .settingsAccessibility(AppsControl.list, localizer)
        .rowMenu(model: model, rows: rows, localizer: localizer)
    }
}

extension View {
    /// Row context menu and double-click to open the details, from macOS 13 (`contextMenu(forSelectionType:)`).
    /// On macOS 12 the Actions column offers the same two commands (ADR 0315).
    @ViewBuilder
    fileprivate func rowMenu(model: SettingsWindowModel, rows: [AppsPaneRow], localizer: Localizer) -> some View {
        if #available(macOS 13, *) {
            contextMenu(forSelectionType: BundleKey.self) { bundles in
                if let bundle = bundles.first {
                    Button(action: { model.reportProblem(for: bundle) }) {
                        Text(verbatim: localizer.string(AppsText.report))
                    }
                    .settingsAccessibility(AppsControl.rowReport, localizer)
                }
            } primaryAction: { bundles in
                if let row = rows.first(where: { bundles.contains($0.bundle) }) { model.showDetail(row) }
            }
        } else {
            self
        }
    }
}

struct AppNameCell: View {
    @ObservedObject var model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        HStack(spacing: 6) {
            if let icon = model.appIdentities.icon(for: row.bundle) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            }
            Text(verbatim: model.appName(of: row)).lineLimit(1).help(Text(verbatim: model.appName(of: row)))
        }
    }
}

/// The row's PRD-R34 rule as a borderless pop-up (title and chevron, no bezel) so the four columns fit the window's
/// minimum width; the menu lists the four rules with a checkmark on the current one.
struct RulePicker: View {
    @ObservedObject var model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        let localizer = model.localizer
        let label = localizer.accessibilityLabel(AppsControl.rowRule) + ": " + model.appName(of: row)
        Menu {
            Picker(selection: Binding(get: { row.rule }, set: { model.setRule($0, for: row.bundle) })) {
                ForEach(PerAppRule.allCases, id: \.self) { rule in
                    Text(verbatim: localizer.string(rule.appsTitle)).tag(rule)
                }
            } label: {
                Text(verbatim: localizer.string(AppsText.columnRule))
            }
            .settingsAccessibility(AppsControl.rowRule, localizer, label: label)
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: localizer.string(row.rule.appsTitle))
        }
        .settingsAccessibility(AppsControl.rowRule, localizer, label: label)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }
}

/// PRD-R35 status: a symbol and the label, so it reads without colour.
struct StatusCell: View {
    let localizer: Localizer
    let status: MatrixStatus

    var body: some View {
        Label {
            Text(verbatim: localizer.string(status.appsTitle))
        } icon: {
            Image(systemName: status.symbolName).accessibilityHidden(true)
        }
    }
}

/// PRD-R37 and the details sheet for the selected row, under the list (keyboard users select a row with the arrow
/// keys, then Tab to these). From macOS 13 the row's context menu and a double-click offer the same (ADR 0315), so
/// the four PRD-R34 columns keep their room at the window's minimum width.
struct AppSelectionActions: View {
    @ObservedObject var model: SettingsWindowModel
    let row: AppsPaneRow?

    var body: some View {
        let localizer = model.localizer
        let name = row.map(model.appName(of:)) ?? ""
        Button(action: { if let row { model.showDetail(row) } }) { Text(verbatim: localizer.string(AppsText.details)) }
            .disabled(row == nil)
            .settingsAccessibility(
                AppsControl.rowDetails, localizer,
                label: localizer.accessibilityLabel(AppsControl.rowDetails) + ": " + name)
        Button(action: { if let row { model.reportProblem(for: row.bundle) } }) {
            Text(verbatim: localizer.string(AppsText.report))
        }
        .disabled(row == nil)
        .settingsAccessibility(
            AppsControl.rowReport, localizer, label: localizer.accessibilityLabel(AppsControl.rowReport) + ": " + name)
    }
}

/// Details (PRD-R35, PRD-R36): status and note, web-app and in-app rows, compatibility mode under Advanced.
struct AppDetailSheet: View {
    @ObservedObject var model: SettingsWindowModel
    @State private var advanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let localizer = model.localizer
        if let detail = model.appDetail {
            let row = detail.row
            VStack(alignment: .leading, spacing: 12) {
                PaneHeading(text: model.appName(of: row))
                Text(verbatim: localizer.format(AppsText.detailBundle, row.bundle.rawValue)).font(.callout)
                    .textSelection(.enabled)
                StatusCell(localizer: localizer, status: row.status)
                if let note = row.noteText(localizer.language) {
                    Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                }
                if let day = detail.lastVerified {
                    Text(verbatim: localizer.format(AppsText.detailLastVerified, localizer.formatDay(iso: day)))
                        .font(.callout)
                }
                ScopedRows(localizer: localizer, detail: detail)
                DisclosureGroup(isExpanded: $advanced) {
                    CompatibilityChoices(model: model, row: row).padding(.top, 6)
                } label: {
                    Text(verbatim: localizer.string(SettingsText.advanced))
                }
                .settingsAccessibility(AppsControl.detailAdvanced, localizer)
                .transaction { if reduceMotion { $0.animation = nil } }
                HStack {
                    Button(action: { model.reportProblem(for: row.bundle) }) {
                        Text(verbatim: localizer.string(AppsText.report))
                    }
                    .settingsAccessibility(AppsControl.detailReport, localizer)
                    Spacer()
                    Button(action: { model.appDetail = nil }) { Text(verbatim: localizer.string(AppsText.detailClose)) }
                        .keyboardShortcut(.cancelAction)
                        .settingsAccessibility(AppsControl.detailClose, localizer)
                }
            }
            .padding(20)
            .frame(width: 480)
            .onAppear { advanced = row.compatibilityMode != .automatic }
        }
    }
}

struct ScopedRows: View {
    let localizer: Localizer
    let detail: AppDetail

    var body: some View {
        if !detail.scoped.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: localizer.string(AppsText.detailScopedTitle)).font(.headline)
                ForEach(detail.scoped, id: \.entry.displayName) { scoped in
                    HStack {
                        Text(verbatim: scoped.entry.displayName)
                        Text(
                            verbatim: localizer.string(
                                scoped.entry.scope == .inApp ? AppsText.scopeInApp : AppsText.scopeWebApp)
                        )
                        .foregroundStyle(.secondary)
                        Spacer()
                        StatusCell(localizer: localizer, status: scoped.status)
                    }
                }
            }
        }
    }
}

/// PRD-R36: automatic plus at most three plain choices, each explained in one sentence; paste asks first. While a
/// guided test result is in force it is listed too, selected but disabled (a state, not a choice), so the pane never
/// shows "automatic" for it (PLT-R540).
struct CompatibilityChoices: View {
    @ObservedObject var model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localizer.string(AppsText.compatTitle)).font(.headline)
            Text(verbatim: localizer.string(AppsText.compatExplanation)).font(.callout).foregroundStyle(.secondary)
            Picker(selection: choice) {
                ForEach(CompatibilityModeChoice.options(current: row.compatibilityMode), id: \.self) { choice in
                    CompatibilityChoiceLabel(localizer: localizer, choice: choice).tag(choice)
                        .disabled(!choice.isSelectable)
                }
            } label: {
                Text(verbatim: localizer.string(AppsText.compatTitle))
            }
            .settingsAccessibility(AppsControl.detailCompatibility, localizer)
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let date = row.compatibilitySetOn {
                Text(verbatim: localizer.format(AppsText.compatSetOn, localizer.formatDate(date))).font(.callout)
            }
        }
    }

    private var choice: Binding<CompatibilityModeChoice> {
        Binding(get: { row.compatibilityMode }, set: { model.chooseCompatibility($0, for: row.bundle) })
    }
}

struct CompatibilityChoiceLabel: View {
    let localizer: Localizer
    let choice: CompatibilityModeChoice

    var body: some View {
        let label = VStack(alignment: .leading) {
            Text(verbatim: localizer.string(choice.title))
            Text(verbatim: localizer.string(choice.explanation)).font(.caption).foregroundStyle(.secondary)
        }
        if choice == .guidedTest {
            // PRD-R66: the guided test's result is a state, not one of the choices; VoiceOver says how to remove it.
            label.settingsAccessibility(AppsControl.detailCompatibilityGuided, localizer)
        } else {
            label
        }
    }
}

/// PRD-R48, PLT-R462: the clipboard explanation before the paste mode is chosen for an app.
struct PasteModeAlert: ViewModifier {
    @ObservedObject var model: SettingsWindowModel

    func body(content: Content) -> some View {
        let localizer = model.localizer
        content.alert(
            Text(verbatim: localizer.string(AppsText.pasteTitle)),
            isPresented: Binding(
                get: { model.pendingPasteMode != nil }, set: { if !$0 { model.pendingPasteMode = nil } })
        ) {
            Button(role: .cancel, action: { model.pendingPasteMode = nil }) {
                Text(verbatim: localizer.string(AppsText.pasteCancel))
            }
            .settingsAccessibility(AppsControl.pasteCancel, localizer)
            Button(action: model.confirmPasteMode) { Text(verbatim: localizer.string(AppsText.pasteConfirm)) }
                .settingsAccessibility(AppsControl.pasteConfirm, localizer)
        } message: {
            Text(verbatim: localizer.format(AppsText.pasteBody, model.appName))
        }
    }
}
