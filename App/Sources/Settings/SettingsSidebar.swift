// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sidebar of the Settings window, like macOS System Settings (Pa, 2026-11-14, feedback item 6): the seven panes
// in PRD-R24 order, each with its SF Symbol on a small coloured rounded tile. A source list with single selection, so
// the arrow keys move between panes (PRD-R67); Command+1 to 7 are handled by `SettingsWindow`. Fixed width, never
// collapsed. The same list runs on macOS 12 and later (ADR 0315).

import AppKit
import AppModel
import ShellCore
import SwiftUI

struct SettingsSidebar: View {
    @ObservedObject var model: SettingsWindowModel
    /// The sidebar runs under the transparent title bar; its first row starts below the window buttons.
    let titleBarHeight: CGFloat

    var body: some View {
        let localizer = model.localizer
        List(selection: selection) {
            ForEach(SettingsPaneKind.allCases, id: \.self) { pane in
                SettingsSidebarRow(title: localizer.string(pane.title), pane: pane).tag(pane)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: max(0, titleBarHeight - SettingsMetrics.sidebarListTopPadding))
        }
        .settingsAccessibility(SettingsControl.panePicker, localizer)
        .frame(width: SettingsWindowLayout.sidebarWidth)
    }

    /// The list never clears the selection: one pane is always shown.
    private var selection: Binding<SettingsPaneKind?> {
        Binding(get: { model.selectedPane }, set: { pane in if let pane { model.select(pane) } })
    }
}

struct SettingsSidebarRow: View {
    let title: String
    let pane: SettingsPaneKind

    var body: some View {
        HStack(spacing: 8) {
            SettingsPaneIcon(pane: pane)
            Text(verbatim: title).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// White symbol on a rounded tile of the pane's colour. Decoration only: the pane's name is beside it and VoiceOver
/// skips it (PRD-R67, PRD-R66). Under Increase Contrast the tile gets an outline.
struct SettingsPaneIcon: View {
    let pane: SettingsPaneKind
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Image(systemName: pane.sidebarSymbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(tile.fill(pane.sidebarTint.color))
            .overlay(tile.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

extension SettingsPaneTint {
    /// System colours, so the tiles follow Dark Mode and Increase Contrast. Allowlisted in the accessibility audit's
    /// hue check: decoration beside a text label, not state.
    var color: Color {
        switch self {
        case .gray: Color(nsColor: NSColor.systemGray)
        case .blue: Color(nsColor: NSColor.systemBlue)
        case .indigo: Color(nsColor: NSColor.systemIndigo)
        case .orange: Color(nsColor: NSColor.systemOrange)
        case .green: Color(nsColor: NSColor.systemGreen)
        case .red: Color(nsColor: NSColor.systemRed)
        case .brown: Color(nsColor: NSColor.systemBrown)
        }
    }
}
