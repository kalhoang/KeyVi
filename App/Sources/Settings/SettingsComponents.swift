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
    @ObservedObject var model: SettingsWindowModel
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

/// "Tùy chọn nâng cao" as its own section: collapsed by default, remembered once expanded (PRD-R24). The view
/// observes the window model: with a plain reference, SwiftUI kept the section's old body when the model published
/// the new state, so a click on the disclosure changed nothing on screen (Pa, 15/11/2026).
struct AdvancedSection: View {
    @ObservedObject var model: SettingsWindowModel
    let pane: SettingsPaneKind

    var body: some View {
        let expanded = Binding(
            get: { model.isAdvancedExpanded(pane) }, set: { model.setAdvancedExpanded($0, for: pane) })
        SettingsGroup {
            SettingsDisclosureHeader(
                title: model.localizer.string(SettingsText.advanced), isExpanded: expanded,
                control: SettingsControl.advancedDisclosure, localizer: model.localizer)
            if expanded.wrappedValue {
                ForEach(SettingsCatalog.items(in: pane, advanced: true), id: \.self) { item in
                    SettingItemRow(model: model, item: item)
                }
            }
        }
    }
}

/// The header row of a disclosure in Settings: the title on the left, the chevron on the right, and the whole row is
/// the click target (a DisclosureGroup on macOS opens only from its small triangle, not from its title). VoiceOver
/// sees a disclosure triangle with its expanded state and the control's label and hint (the accessibility
/// representation, PRD-R66); keyboard users reach it with Tab and press Space, and the plain-style row draws its own
/// focus ring (PRD-R67). The content is the caller's: rows of their own after the header in a
/// grouped section, or a view under it (`SettingsDisclosure`). No animation with Reduce Motion (PRD-R67).
struct SettingsDisclosureHeader<Control: AccessibleControl>: View {
    let title: String
    @Binding var isExpanded: Bool
    var font: Font = .headline
    let control: Control
    let localizer: Localizer
    /// Overrides the control's label, for example to add the licence's name.
    var label: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
            HStack(spacing: 8) {
                Text(verbatim: title).font(font)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .padding(-4)
                    .opacity(focused ? 1 : 0))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .systemFocusEffectDisabled()
        .accessibilityRepresentation {
            DisclosureGroup(isExpanded: $isExpanded) {
                EmptyView()
            } label: {
                Text(verbatim: title)
            }
            .settingsAccessibility(control, localizer, label: label)
        }
        .settingsAccessibility(control, localizer, label: label)
    }
}

/// A disclosure outside a grouped section's rows (the Apps details sheet, the Licences pane): the header row, then
/// the content under it while expanded.
struct SettingsDisclosure<Control: AccessibleControl, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var font: Font = .headline
    let control: Control
    let localizer: Localizer
    var label: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsDisclosureHeader(
                title: title, isExpanded: $isExpanded, font: font, control: control, localizer: localizer,
                label: label)
            if isExpanded { content }
        }
    }
}

/// PRD-R26 per-pane reset as the last section: what it does on the left, the button that opens the confirmation
/// (with the export offer) on the right.
struct PaneResetSection<Control: AccessibleControl>: View {
    @ObservedObject var model: SettingsWindowModel
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
    @ObservedObject var model: SettingsWindowModel
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
