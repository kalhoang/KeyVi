// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Ứng dụng / Apps" (PRD-R34-R38): apps typed in (most recent first) and apps with rules, with icon and name,
// rule, remembered mode and compatibility status (symbol plus text, never colour alone, PRD-R67). Each row offers
// the details sheet and "Báo lỗi với ứng dụng này..." (PRD-R37). The list scrolls (PRD-R24 acceptance).

import AppKit
import AppModel
import CompatRules
import ShellCore
import SwiftUI

struct AppsPaneView: View {
    let model: SettingsWindowModel
    @State private var selection: BundleKey?

    var body: some View {
        let localizer = model.localizer
        let rows = model.appRows
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localizer.string(AppsText.explanation)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(verbatim: localizer.string(AppsText.empty))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
            } else {
                AppsTable(model: model, rows: rows, selection: $selection)
            }
            PaneResetButton(model: model, target: .pane(.apps), control: AppsControl.resetPane)
        }
    }
}

struct AppsTable: View {
    let model: SettingsWindowModel
    let rows: [AppsPaneRow]
    @Binding var selection: BundleKey?

    var body: some View {
        let localizer = model.localizer
        Table(rows, selection: $selection) {
            TableColumn(localizer.string(AppsText.columnApp)) { row in AppNameCell(model: model, row: row) }
                .width(min: 150, ideal: 200)
            TableColumn(localizer.string(AppsText.columnRule)) { row in RulePicker(model: model, row: row) }
                .width(min: 130, ideal: 150)
            TableColumn(localizer.string(AppsText.columnRemembered)) { row in
                Text(verbatim: localizer.string(row.rememberedModeTitle))
            }
            .width(min: 70, ideal: 90)
            TableColumn(localizer.string(AppsText.columnStatus)) { row in
                StatusCell(localizer: localizer, status: row.status)
            }
            .width(min: 120, ideal: 150)
            TableColumn(localizer.string(AppsText.columnActions)) { row in AppRowActions(model: model, row: row) }
                .width(min: 110, ideal: 120)
        }
        .settingsAccessibility(AppsControl.list, localizer)
        .contextMenu(forSelectionType: BundleKey.self) { bundles in
            if let bundle = bundles.first {
                Button(action: { model.reportProblem(for: bundle) }) {
                    Text(verbatim: localizer.string(AppsText.report))
                }
                .settingsAccessibility(AppsControl.rowReport, localizer)
            }
        } primaryAction: { bundles in
            if let row = rows.first(where: { bundles.contains($0.bundle) }) { model.showDetail(row) }
        }
    }
}

struct AppNameCell: View {
    let model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        HStack(spacing: 6) {
            if let icon = model.appIdentities.icon(for: row.bundle) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            }
            Text(verbatim: model.appName(of: row)).lineLimit(1)
        }
    }
}

struct RulePicker: View {
    let model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        let localizer = model.localizer
        Picker(selection: Binding(get: { row.rule }, set: { model.setRule($0, for: row.bundle) })) {
            ForEach(PerAppRule.allCases, id: \.self) { rule in
                Text(verbatim: localizer.string(rule.appsTitle)).tag(rule)
            }
        } label: {
            Text(verbatim: localizer.string(AppsText.columnRule))
        }
        .labelsHidden()
        .settingsAccessibility(
            AppsControl.rowRule, localizer,
            label: localizer.accessibilityLabel(AppsControl.rowRule) + ": "
                + model.appName(of: row))
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

struct AppRowActions: View {
    let model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        let localizer = model.localizer
        let name = model.appName(of: row)
        HStack(spacing: 6) {
            Button(action: { model.showDetail(row) }) { Text(verbatim: localizer.string(AppsText.details)) }
                .settingsAccessibility(
                    AppsControl.rowDetails, localizer,
                    label: localizer.accessibilityLabel(AppsControl.rowDetails) + ": " + name)
            Button(action: { model.reportProblem(for: row.bundle) }) {
                Image(systemName: "exclamationmark.bubble").accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: localizer.string(AppsText.report)))
            .settingsAccessibility(
                AppsControl.rowReport, localizer,
                label: localizer.accessibilityLabel(AppsControl.rowReport) + ": " + name)
        }
    }
}

/// Details (PRD-R35, PRD-R36): status and note, web-app and in-app rows, compatibility mode under Advanced.
struct AppDetailSheet: View {
    let model: SettingsWindowModel
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

/// PRD-R36: automatic plus at most three plain choices, each explained in one sentence; paste asks first.
struct CompatibilityChoices: View {
    let model: SettingsWindowModel
    let row: AppsPaneRow

    var body: some View {
        let localizer = model.localizer
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localizer.string(AppsText.compatTitle)).font(.headline)
            Text(verbatim: localizer.string(AppsText.compatExplanation)).font(.callout).foregroundStyle(.secondary)
            Picker(selection: choice) {
                ForEach(CompatibilityModeChoice.allCases, id: \.self) { choice in
                    CompatibilityChoiceLabel(localizer: localizer, choice: choice).tag(choice)
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
        VStack(alignment: .leading) {
            Text(verbatim: localizer.string(choice.title))
            Text(verbatim: localizer.string(choice.explanation)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// PRD-R48, PLT-R462: the clipboard explanation before the paste mode is chosen for an app.
struct PasteModeAlert: ViewModifier {
    @Bindable var model: SettingsWindowModel

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
