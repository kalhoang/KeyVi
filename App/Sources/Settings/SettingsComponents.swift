// SPDX-License-Identifier: GPL-3.0-or-later
//
// Building blocks shared by the panes: a setting with its one-line explanation (PRD-R25), the remembered
// Advanced disclosure (PRD-R24), the per-pane reset button (PRD-R26) and the VoiceOver label and hint modifier
// (PRD-R66). Copy is rendered with `Text(verbatim:)` from the selected language (ADR 0310).

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

/// A control with its one-line explanation underneath (PRD-R25).
struct SettingRow<Control: View>: View {
    let localizer: Localizer
    let item: SettingItem
    var arguments: [any CVarArg] = []
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            Text(verbatim: localizer.format(item.explanation.key, table: item.explanation.table, arguments: arguments))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Bool setting as a checkbox-style toggle with its explanation.
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
        }
    }
}

/// "Tùy chọn nâng cao": collapsed by default, remembered once expanded (PRD-R24). No animation with Reduce
/// Motion (PRD-R67).
struct AdvancedSection<Content: View>: View {
    let model: SettingsWindowModel
    let pane: SettingsPaneKind
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let expanded = Binding(
            get: { model.isAdvancedExpanded(pane) }, set: { model.setAdvancedExpanded($0, for: pane) })
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: model.localizer.string(SettingsText.advanced)).font(.headline)
        }
        .settingsAccessibility(SettingsControl.advancedDisclosure, model.localizer)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// PRD-R26 per-pane reset (opens the confirmation with the export offer).
struct PaneResetButton<Control: AccessibleControl>: View {
    let model: SettingsWindowModel
    let target: ResetTarget
    let control: Control

    var body: some View {
        HStack {
            Spacer()
            Button(action: { model.requestReset(target) }) {
                Text(verbatim: model.localizer.string(SettingsText.resetPane))
            }
            .settingsAccessibility(control, model.localizer)
        }
    }
}

/// A section heading inside a pane.
struct PaneHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Store notices at the top of the window (PLT-R1006, PLT-R1007, PLT-R1009). Warnings carry a symbol, not only a
/// colour (PRD-R67).
struct NoticeBanner: View {
    @ObservedObject var model: SettingsWindowModel
    let notice: StoreNoticePresentation

    var body: some View {
        let localizer = model.localizer
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle.fill" : SettingsSymbol.infoFill)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .accessibilityElement(children: .contain)
    }
}
