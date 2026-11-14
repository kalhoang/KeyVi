// SPDX-License-Identifier: GPL-3.0-or-later
//
// Building blocks shared by the panes: a setting row with its one-line explanation (PRD-R25), a switch setting, the
// remembered Advanced disclosure (PRD-R24), the per-pane reset section (PRD-R26), store notices and the VoiceOver
// label and hint modifier (PRD-R66). Copy is rendered with `Text(verbatim:)` from the selected language (ADR 0310).

import AppModel
import ShellCore
import SwiftUI

extension View {
    /// VoiceOver label and hint from a W2-B catalog (PRD-R66). `label` overrides the label key when the visible
    /// title is the better label (for example a list entry).
    func settingsAccessibility<Control: AccessibleControl>(
        _ control: Control, _ localizer: Localizer, label: String? = nil
    ) -> some View {
        accessibilityLabel(Text(verbatim: label ?? localizer.accessibilityLabel(control)))
            .accessibilityHint(Text(verbatim: localizer.accessibilityHint(control)))
    }
}

/// A setting's row: its title and explanation from the catalog, its control on the right (PRD-R25).
struct SettingRow<Control: View>: View {
    let localizer: Localizer
    let item: SettingItem
    var arguments: [any CVarArg] = []
    @ViewBuilder var control: Control

    var body: some View {
        SettingsFormRow(title: localizer.string(item.title), explanation: explanation) { control }
    }

    private var explanation: String {
        localizer.format(item.explanation.key, table: item.explanation.table, arguments: arguments)
    }
}

/// A Bool setting as a switch on the right of its title and explanation, like System Settings.
struct ToggleSetting<Control: AccessibleControl>: View {
    let model: SettingsWindowModel
    let item: SettingItem
    let control: Control
    let isOn: Bool
    let edit: (Bool) -> SettingsEdit

    var body: some View {
        let localizer = model.localizer
        SettingRow(localizer: localizer, item: item) {
            Toggle(isOn: Binding(get: { isOn }, set: { model.edit(edit($0)) })) {
                Text(verbatim: localizer.string(item.title))
            }
            .settingsAccessibility(control, localizer)
            .settingsSwitch()
        }
    }
}

extension View {
    /// The small switch of System Settings, without the visible label (the row shows the title).
    func settingsSwitch() -> some View {
        toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}

/// "Tùy chọn nâng cao" as its own section: collapsed by default, remembered once expanded (PRD-R24). No animation
/// with Reduce Motion (PRD-R67).
struct AdvancedSection: View {
    let model: SettingsWindowModel
    let pane: SettingsPaneKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = Binding(
            get: { model.isAdvancedExpanded(pane) }, set: { model.setAdvancedExpanded($0, for: pane) })
        SettingsGroup {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(SettingsCatalog.items(in: pane, advanced: true), id: \.self) { item in
                    SettingItemRow(model: model, item: item)
                }
            } label: {
                Text(verbatim: model.localizer.string(SettingsText.advanced)).font(.headline)
            }
            .settingsAccessibility(SettingsControl.advancedDisclosure, model.localizer)
            .transaction { if reduceMotion { $0.animation = nil } }
        }
    }
}

/// PRD-R26 per-pane reset as the last section: what it does on the left, the button that opens the confirmation
/// (with the export offer) on the right.
struct PaneResetSection<Control: AccessibleControl>: View {
    let model: SettingsWindowModel
    let target: ResetTarget
    let control: Control

    var body: some View {
        SettingsGroup {
            SettingsFormRow(title: model.localizer.string(SettingsText.resetPaneExplanation)) {
                PaneResetButton(model: model, target: target, control: control)
            }
        }
    }
}

struct PaneResetButton<Control: AccessibleControl>: View {
    let model: SettingsWindowModel
    let target: ResetTarget
    let control: Control

    var body: some View {
        Button(action: { model.requestReset(target) }) {
            Text(verbatim: model.localizer.string(SettingsText.resetPane))
        }
        .settingsAccessibility(control, model.localizer)
    }
}

/// A heading inside a sheet.
struct PaneHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Store notices at the top of the pane (PLT-R1006, PLT-R1007, PLT-R1009). Warnings carry a symbol, not only a
/// colour (PRD-R67).
struct NoticeBanner: View {
    @ObservedObject var model: SettingsWindowModel
    let notice: StoreNoticePresentation

    var body: some View {
        let localizer = model.localizer
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : SettingsSymbol.infoFill)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: notice.message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    ForEach(notice.actions, id: \.self) { action in
                        Button(action: { model.perform(action) }) { Text(verbatim: localizer.string(action.title)) }
                            .settingsAccessibility(action.control, localizer)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.listCornerRadius, style: .continuous).fill(.quaternary)
        )
        .accessibilityElement(children: .contain)
    }
}
