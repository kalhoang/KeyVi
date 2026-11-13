// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Menu-bar status item and menu (PRD-R9-R13), switch HUD (PRD-R12) and capture HUD (PLT-R905).
// Workstream W1-G.

import AppKit
import AppModel
import ShellCore

/// Actions the menu triggers; implemented by AppEnvironment.
@MainActor
protocol StatusMenuActions: AnyObject {
    func setMode(_ mode: TypingMode)
    func setMethod(_ method: TypingMethod)
    func setRule(_ rule: PerAppRule, for bundle: BundleKey)
    func reportProblem(for bundle: BundleKey?)
    func openMacros()
    func openSettings()
    func checkForUpdates()
    func openSupport()
    func performStatusAction(_ action: StatusLine.Action)
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// `menuModel` is called from `menuNeedsUpdate(_:)` so the menu is rebuilt on every open (PRD-R13).
    init(
        language: InterfaceLanguageModel, actions: any StatusMenuActions, menuModel: @escaping @MainActor () -> MenuModel
    ) { unimplemented() }

    /// Template image `StatusIconState.templateImageName` plus `accessibilityLabel` from the Menu table.
    func show(_ state: StatusIconState) { unimplemented() }
    /// D16: primary click toggles when enabled; the menu then opens on secondary click.
    func setClickToToggle(_ enabled: Bool) { unimplemented() }
    func menuNeedsUpdate(_ menu: NSMenu) { unimplemented() }
}

/// Non-activating panel near the bottom centre showing V or E for 600 ms; respects Reduce Motion; posts an
/// accessibility announcement; never shown for automatic per-app switches (PRD-R12, PRD-R66).
@MainActor
final class SwitchHUDController {
    init(language: InterfaceLanguageModel) { unimplemented() }
    func show(_ mode: TypingMode) { unimplemented() }
}

/// Floating countdown with a Stop button on all Spaces and above full-screen apps while a typing trace
/// records (PLT-R905).
@MainActor
final class CaptureHUDController {
    init(language: InterfaceLanguageModel, stop: @escaping @MainActor () -> Void) { unimplemented() }
    func show(remaining: Duration) { unimplemented() }
    func hide() { unimplemented() }
}
