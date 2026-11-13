// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window with at most five panes (PRD-R24-R28), macros editor (PRD-R29-R33) and Apps pane
// (PRD-R34-R38). Workstream W2-B. A normal window (not floating) whose size and position are remembered
// (PRD-R28); SwiftUI content in an NSHostingController (ADR 0305).

import AppKit
import AppModel
import Combine
import CompatRules
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

/// The pane identifiers used by the composition root (`show(.macros)`, `show(.aboutSupport)`).
typealias SettingsPane = SettingsPaneKind

/// What the Settings window asks the composition root to do; implemented by AppEnvironment.
@MainActor
protocol SettingsActions: AnyObject {
    /// "Báo lỗi..." (About & Support, safe-mode notice) and "Báo lỗi với ứng dụng này..." (PRD-R37): the bug report
    /// sheet, pre-filled with `bundle` when given.
    func reportProblemFromSettings(for bundle: BundleKey?)
    /// "Chẩn đoán..." (D26 entry, W2-C's diagnostics window).
    func openDiagnostics()
    /// PRD-R40: onboarding can be reopened from About & Support.
    func reopenOnboarding()
    /// ADR 0305: the tap suspends hotkeys while the recorder captures keys
    /// (`InputHostController.setRecorderActive(_:)`).
    func setHotkeyRecorderActive(_ active: Bool)
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let frameAutosaveName = "SettingsWindow"
    static let defaultSize = NSSize(width: 700, height: 620)
    static let minimumSize = NSSize(width: 640, height: 560)

    private let model: SettingsWindowModel
    private var languageObservation: AnyCancellable?

    /// Forwarded to the model; set by the composition root after construction.
    weak var actions: (any SettingsActions)? {
        didSet { model.actions = actions }
    }

    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - brand: app name, slug, version and site host (never hard-coded).
    ///   - matrix: the bundled `compat-matrix.json`; nil shows every app as not verified (PRD-R35).
    ///   - panes: System Settings / System Preferences names of the running macOS (PRD-R64, ADR 0315).
    ///   - inputSources: enabled input sources for the layout binding (PLT-R373), read when the pane appears.
    ///   - layout: the current layout table, so the recorder names Command+Q / Command+W on any layout.
    init(
        store: SettingsStore, language: InterfaceLanguageModel, updater: any UpdaterControlling,
        loginItem: any LoginItemService, brand: Brand = .from(.main),
        matrix: MatrixDocument? = SettingsResources.bundledMatrix(), panes: SystemPaneNames,
        inputSources: @escaping @MainActor () -> [InputSourceInfo] = { [] },
        layout: @escaping @MainActor () -> LayoutTable? = { nil },
        keyValues: any KeyValueStore = UserDefaultsKeyValueStore()
    ) {
        model = SettingsWindowModel(
            commands: SettingsCommands(store: store), language: language, updater: updater, loginItem: loginItem,
            brand: brand, matrix: matrix, panes: panes, inputSources: inputSources, layout: layout,
            disclosures: AdvancedDisclosureMemory(store: keyValues))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.level = .normal  // PRD-R28: does not float above other apps
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)  // PRD-R28: size and position remembered
        super.init(window: window)
        window.delegate = self
        refreshTitle()
        observeLanguage()
    }

    /// Shows the window on `pane` (menu "Cài đặt...", "Gõ tắt...", "Ủng hộ...", the URL scheme, PLT-R909).
    func show(_ pane: SettingsPane) {
        model.select(pane)
        present()
    }

    /// Opens the General pane with the toggle recorder already recording and focused. `role: .restoreLastWord`
    /// opens the Typing pane's restore recorder instead. Onboarding screen 4 records inline (PRD-R40).
    func showHotkeyRecorder(role: HotkeyRole = .toggleMode) {
        model.select(role == .toggleMode ? .general : .typing)
        if role == .restoreLastWord { model.setAdvancedExpanded(true, for: .typing) }
        present()
        model.startRecording(role)
    }

    /// The composition root forwards `SettingsStore`'s `onChange` here on the main actor, so changes made
    /// elsewhere (menu, per-app memory, import) show at once.
    func settingsChanged(_ state: SettingsState) {
        model.apply(state)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
    }

    /// ADR 0305, PRD-R67: once another app or window takes the keyboard, the recorder stops swallowing keys and
    /// the tap's hotkeys work again.
    func windowDidResignKey(_ notification: Notification) {
        model.interruptRecording()
    }

    private func present() {
        Task { await model.refresh() }
        showWindow(nil)
        NSApp.bringToFront()
        window?.makeKeyAndOrderFront(nil)
    }

    /// PRD-R63: the title follows a language change; SwiftUI content re-renders by itself.
    private func refreshTitle() {
        window?.title = model.localizer.format(SettingsText.windowTitle, model.brand.displayName)
    }

    private func observeLanguage() {
        languageObservation = model.language.afterChange { [weak self] in self?.refreshTitle() }
    }
}

/// Bundled data the window reads.
enum SettingsResources {
    /// `compat-matrix.json` copied into the bundle by the build (PRD-R38); nil when missing or invalid.
    static func bundledMatrix(bundle: Bundle = .main) -> MatrixDocument? {
        bundle.url(forResource: "compat-matrix", withExtension: "json").flatMap(MatrixLoader.load(contentsOf:))
    }
}
