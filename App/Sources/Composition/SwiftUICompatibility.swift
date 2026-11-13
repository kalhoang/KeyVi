// SPDX-License-Identifier: LicenseRef-App-Pending
//
// SwiftUI APIs newer than the macOS 12 floor, with the macOS 12 fallback next to each (ADR 0315). Views call
// these instead of checking availability themselves, so the label-and-hint audit still sees plain controls.

import SwiftUI

extension TextField where Label == Text {
    /// A field that grows to several lines from macOS 13 (`axis: .vertical`) and stays on one line on macOS 12.
    /// Pair it with `reservingLines(_:)`.
    init(growing text: Binding<String>, placeholder: String) {
        if #available(macOS 13, *) {
            self.init(text: text, axis: .vertical) { Text(verbatim: placeholder) }
        } else {
            self.init(text: text) { Text(verbatim: placeholder) }
        }
    }
}

extension View {
    /// `lineLimit(_:reservesSpace:)` from macOS 13; on macOS 12 the growing field is one line and keeps its size.
    @ViewBuilder
    func reservingLines(_ lines: Int) -> some View {
        if #available(macOS 13, *) {
            lineLimit(lines, reservesSpace: true)
        } else {
            self
        }
    }

    /// `shortcut` only while `condition` holds. `keyboardShortcut(_:)` with an optional shortcut needs macOS 12.3.
    @ViewBuilder
    func keyboardShortcut(_ shortcut: KeyboardShortcut, when condition: Bool) -> some View {
        if condition {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }

    /// Hides the system focus effect where the view draws its own ring (PRD-R67). `focusEffectDisabled()` exists
    /// from macOS 14; earlier systems show their focus ring as well, which still marks the focused control.
    @ViewBuilder
    func systemFocusEffectDisabled() -> some View {
        if #available(macOS 14, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
