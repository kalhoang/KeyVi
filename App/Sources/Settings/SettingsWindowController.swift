// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings window with at most five panes (PRD-R24-R28), macros editor (PRD-R29-R33) and Apps pane
// (PRD-R34-R38). Workstream W2-B.

import AppKit
import AppModel
import SettingsStore
import ShellCore

enum SettingsPane: String, CaseIterable {
    case general, typing, apps, macros, aboutSupport
}

@MainActor
final class SettingsWindowController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    init(
        store: SettingsStore, language: InterfaceLanguageModel, updater: any UpdaterControlling,
        loginItem: any LoginItemService
    ) { unimplemented() }

    func show(_ pane: SettingsPane) { unimplemented() }
}
