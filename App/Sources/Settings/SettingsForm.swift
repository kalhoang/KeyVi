// SPDX-License-Identifier: GPL-3.0-or-later
//
// Containers of the System Settings style layout (Pa, 2026-11-14, feedback item 6; PRD-R24): a pane is a grouped
// Form from macOS 13 (`.formStyle(.grouped)`); macOS 12 has no grouped form style (ADR 0315), so it gets a scroll
// view of GroupBox sections that looks close. Rows are the same in both: title and one-line explanation (PRD-R25) on
// the left, the control on the right.

import AppModel
import ShellCore
import SwiftUI

/// Which container the panes use. `.automatic` picks the grouped Form where the system has it; `.legacy` forces the
/// macOS 12 layout (the snapshot tool renders it on any system).
enum SettingsLayoutStyle: Sendable, Hashable {
    case automatic, legacy
}

private struct SettingsLayoutStyleKey: EnvironmentKey {
    static let defaultValue = SettingsLayoutStyle.automatic
}

extension EnvironmentValues {
    var settingsLayoutStyle: SettingsLayoutStyle {
        get { self[SettingsLayoutStyleKey.self] }
        set { self[SettingsLayoutStyleKey.self] = newValue }
    }
}

/// Spacing of the layout, in points: the grouped Form's own insets, which the macOS 12 sections and the list panes
/// copy so every pane lines up.
enum SettingsMetrics {
    static let paneInset: CGFloat = 20
    /// The Apps and Macros lists use a little more of the width, so their columns fit the minimum window.
    static let listPaneInset: CGFloat = 14
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 16
    static let listCornerRadius: CGFloat = 8
}

/// A pane's scrolling content made of `SettingsGroup` sections.
struct SettingsPaneForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.settingsLayoutStyle) private var style

    var body: some View {
        if #available(macOS 13, *), style == .automatic {
            Form { content }
                .formStyle(.grouped)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) { content }
                    .padding(SettingsMetrics.paneInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One rounded section with an optional header above and footer below.
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.settingsLayoutStyle) private var style

    var body: some View {
        if #available(macOS 13, *), style == .automatic {
            Section {
                content
            } header: {
                if let header { SectionHeader(text: header) }
            } footer: {
                if let footer { SectionFooter(text: footer) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let header { SectionHeader(text: header).padding(.leading, 4) }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) { content }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let footer { SectionFooter(text: footer).padding(.horizontal, 4) }
            }
        }
    }
}

struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SectionFooter: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row: title and explanation on the left (PRD-R25), the control on the right at its natural size.
struct SettingsFormRow<Control: View>: View {
    let title: String
    var explanation: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: SettingsMetrics.rowSpacing) {
            RowLabel(title: title, explanation: explanation)
            control.fixedSize()
        }
    }
}

/// Title over its secondary one-line explanation, wrapping instead of truncating at any window width.
struct RowLabel: View {
    let title: String
    var explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
            if let explanation {
                Text(verbatim: explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TextField where Label == Text {
    /// A field whose text is a placeholder, never a label beside it: grouped forms (macOS 13 and later) lay a field's
    /// label out on the left, so the Settings fields pass it as the prompt and hide the label (`labelsHidden()` at the
    /// call site, which also carries the VoiceOver label and hint). `growing` grows the field to several lines from
    /// macOS 13; on macOS 12 it stays on one line (ADR 0315).
    init(settingsText text: Binding<String>, prompt: String, growing: Bool = false) {
        if #available(macOS 13, *), growing {
            self.init(text: text, prompt: Text(verbatim: prompt), axis: .vertical) { Text(verbatim: prompt) }
        } else {
            self.init(text: text, prompt: Text(verbatim: prompt)) { Text(verbatim: prompt) }
        }
    }
}

/// A list in a rounded box like the lists of System Settings (Apps, Macros, the ENG-R860 word lists).
struct ListBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.listCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.listCornerRadius, style: .continuous)
                    .strokeBorder(.separator))
    }
}
