// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R24: "Tùy chọn nâng cao" opens and closes when it is clicked (Pa, 15/11/2026: in General and Typing it could
// not be opened). A click on the disclosure sets the window model's expanded state through the disclosure's binding;
// this test makes the same change on a drawn window and checks that the drawn pane changes with it, in the grouped
// Form (macOS 13 and later) and in the macOS 12 layout. The snapshots never showed the bug because they set the state
// before the window was built. Host safety as in SettingsSnapshotTests: the window is drawn offscreen, never shown.

import AppKit
import AppModel
import ShellCore
import Testing

@MainActor
@Suite(.serialized) struct AdvancedDisclosureTests {
    /// Tall enough that the Advanced section of every pane is inside the drawn area.
    static let size = NSSize(width: SettingsWindowLayout.defaultWidth, height: 1_400)

    @Test func theDrawnPaneFollowsTheAdvancedDisclosure_PRDR24() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)  // no Dock icon, no menu bar, never active
        let panes = SettingsPaneKind.allCases.filter(\.hasAdvancedSection)
        #expect(panes == [.general, .typing])
        for pane in panes {
            for legacyLayout in [false, true] {
                let store = try await SnapshotFixtures.store(matrix: nil)
                let model = try await SnapshotFixtures.model(language: .vietnamese, store: store.store, matrix: nil)
                model.select(pane)
                let window = SnapshotFixtures.window(
                    size: Self.size, model: model, dark: false, legacyLayout: legacyLayout)
                let collapsed = try SettingsSnapshotTests.render(window)
                // What a click on the disclosure does: its binding sets the model's state.
                model.setAdvancedExpanded(true, for: pane)
                let expanded = try SettingsSnapshotTests.render(window)
                model.setAdvancedExpanded(false, for: pane)
                let collapsedAgain = try SettingsSnapshotTests.render(window)
                let name = "\(pane.rawValue)\(legacyLayout ? " (macOS 12 layout)" : "")"
                #expect(collapsed != expanded, "\(name): opening Advanced options did not change the pane")
                #expect(expanded != collapsedAgain, "\(name): closing Advanced options did not change the pane")
                window.contentView = nil
                await SnapshotFixtures.discard(store)
            }
        }
    }
}
