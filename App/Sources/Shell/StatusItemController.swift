// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Menu-bar status item and menu (PRD-R9-R13), switch HUD (PRD-R12) and capture HUD (PLT-R905).
// Workstream W1-G.

import AppKit
import AppModel
import Combine
import RealtimeSupport
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
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let language: InterfaceLanguageModel
    private let menuModel: @MainActor () -> MenuModel
    private weak var actions: (any StatusMenuActions)?
    private var iconState: StatusIconState = .notWorking
    private var labelKey: String?
    private var appName: String?
    private var clickToToggle = false
    private var languageObservation: AnyCancellable?

    /// `menuModel` is called from `menuNeedsUpdate(_:)` so the menu is rebuilt on every open (PRD-R13).
    init(
        language: InterfaceLanguageModel, actions: any StatusMenuActions,
        menuModel: @escaping @MainActor () -> MenuModel
    ) {
        self.language = language
        self.actions = actions
        self.menuModel = menuModel
        // PRD-R9: always visible; the default behavior does not allow the user to remove it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked(_:))
        applyIcon()
        observeLanguage()
    }

    /// Catalog image `StatusIconState.imageName` (via `StatusGlyph`) plus `accessibilityLabel` from the Menu table.
    func show(_ state: StatusIconState) {
        show(state, accessibilityLabelKey: nil)
    }

    /// `accessibilityLabelKey` from `StatusPresentation.accessibilityLabelKey(icon:state:)` keeps the VoiceOver
    /// label truthful for states that share a glyph (PLT-R211).
    func show(_ state: StatusIconState, accessibilityLabelKey: String?) {
        iconState = state
        labelKey = accessibilityLabelKey
        appName = menuModel().appName
        applyIcon()
    }

    /// D16: primary click toggles when enabled; the menu then opens on secondary click.
    func setClickToToggle(_ enabled: Bool) {
        clickToToggle = enabled
        statusItem.menu = enabled ? nil : menu
        statusItem.button?.sendAction(on: enabled ? [.leftMouseUp, .rightMouseUp] : [.leftMouseUp])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = menuModel()
        appName = model.appName
        menu.removeAllItems()
        let builder = StatusMenuBuilder(localizer: language.localizer, target: self)
        for entry in model.entries { menu.addItem(builder.item(for: entry, model: model)) }
    }

    // MARK: - Icon and language

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        // Not a template: the variant follows the button's effective appearance (StatusGlyph).
        button.image = StatusGlyph.image(for: iconState)
        let localizer = language.localizer
        button.setAccessibilityLabel(localizer.string(labelKey ?? iconState.accessibilityLabelKey, table: .menu))
        if let appName { button.setAccessibilityHelp(localizer.format(MenuText.statusItemHint, appName)) }
    }

    /// PRD-R63: the status item's label follows a language change at once; the menu is rebuilt on next open.
    private func observeLanguage() {
        languageObservation = language.afterChange { [weak self] in self?.applyIcon() }
    }

    // MARK: - Actions (targets of the menu items built by StatusMenuBuilder)

    @objc private func statusButtonClicked(_ sender: Any?) {
        guard clickToToggle else { return }
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            actions?.setMode(menuModel().mode.toggled)
        }
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TypingMode(rawValue: raw) else { return }
        actions?.setMode(mode)
    }

    @objc func selectMethod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let method = TypingMethod(rawValue: raw) else { return }
        actions?.setMethod(method)
    }

    @objc func selectRule(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? RuleChoice else { return }
        actions?.setRule(choice.rule, for: choice.bundle)
    }

    @objc func reportForApp(_ sender: NSMenuItem) {
        actions?.reportProblem(for: (sender.representedObject as? BundleChoice)?.bundle)
    }

    @objc func reportProblem(_ sender: NSMenuItem) { actions?.reportProblem(for: nil) }
    @objc func openMacros(_ sender: NSMenuItem) { actions?.openMacros() }
    @objc func openSettings(_ sender: NSMenuItem) { actions?.openSettings() }
    @objc func checkForUpdates(_ sender: NSMenuItem) { actions?.checkForUpdates() }
    @objc func openSupport(_ sender: NSMenuItem) { actions?.openSupport() }

    @objc func performStatusAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? StatusActionBox)?.action else { return }
        actions?.performStatusAction(action)
    }
}

/// Non-activating panel near the bottom centre showing V or E for 600 ms; respects Reduce Motion; posts an
/// accessibility announcement; never shown for automatic per-app switches (PRD-R12, PRD-R66).
@MainActor
final class SwitchHUDController {
    private let language: InterfaceLanguageModel
    private let panel = HUDPanelFactory.switchPanel()
    private var indicator: SwitchIndicator?

    convenience init(language: InterfaceLanguageModel) {
        self.init(language: language, scheduler: DispatchTimerScheduler(queue: .main))
    }

    /// `scheduler` must deliver on the main queue; timing lives in ShellCore's `SwitchIndicator`.
    init(language: InterfaceLanguageModel, scheduler: any TimerScheduler) {
        self.language = language
        indicator = SwitchIndicator(scheduler: scheduler) { [weak self] change in self?.apply(change) }
    }

    /// Callers pass only manual toggles with D14 on (`SwitchIndicator.shouldShow`); automatic per-app switches
    /// never reach here (PRD-R12).
    func show(_ mode: TypingMode) {
        indicator?.show(mode)
    }

    private func apply(_ change: SwitchIndicator.Change) {
        switch change {
        case .show(let mode):
            let localizer = language.localizer
            let glyph = localizer.string(mode == .vietnamese ? MenuText.hudVietnameseGlyph : MenuText.hudEnglishGlyph)
            let announcement = localizer.string(
                mode == .vietnamese ? MenuText.hudVietnameseAnnouncement : MenuText.hudEnglishAnnouncement)
            HUDPanelFactory.present(panel, content: SwitchHUDView(glyph: glyph, label: announcement))
            HUDPanelFactory.announce(announcement, from: panel)  // PRD-R66
        case .hide:
            HUDPanelFactory.dismiss(panel)
        }
    }
}

/// Floating countdown with a Stop button on all Spaces and above full-screen apps while a typing trace
/// records (PLT-R905).
@MainActor
final class CaptureHUDController {
    private let language: InterfaceLanguageModel
    private let stop: @MainActor () -> Void
    private let panel = HUDPanelFactory.capturePanel()

    init(language: InterfaceLanguageModel, stop: @escaping @MainActor () -> Void) {
        self.language = language
        self.stop = stop
    }

    func show(remaining: TimeSpan) {
        let localizer = language.localizer
        let content = CaptureHUDView(
            title: localizer.string(MenuText.captureTitle),
            remaining: localizer.format(MenuText.captureRemaining, localizer.formatCountdown(remaining)),
            stopTitle: localizer.string(MenuText.captureStop),
            stopLabel: localizer.string(MenuText.captureStopLabel),
            stopHint: localizer.string(MenuText.captureStopHint),
            stop: { [weak self] in self?.stop() })
        HUDPanelFactory.presentCapture(panel, content: content)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
