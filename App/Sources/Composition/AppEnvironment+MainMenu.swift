// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main menu's own commands (PRD-R28 amended 15/11/2026, `MainMenuController`): About opens Settings on the About
// pane, Settings... (Command+,) and the Dock icon bring Settings forward on the pane the user left open.

import AppKit

extension AppEnvironment {
    func showAboutFromMainMenu() { settingsController()?.show(.about) }

    func showSettingsFromMainMenu() { settingsController()?.showKeepingPane() }
}
