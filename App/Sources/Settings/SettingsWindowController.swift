// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window with seven panes (PRD-R24-R28), macros editor (PRD-R29-R33) and Apps pane
// (PRD-R34-R38). Workstream W2-B; System Settings style sidebar layout W8-D (Pa, 2026-11-14). A normal window (not
// floating) whose size and position are remembered (PRD-R28); SwiftUI content in an NSHostingController (ADR 0305).

import AppKit
import AppModel
import Combine
import CompatRules
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

/// The pane identifiers used by the composition root (`show(.macros)`, `show(.about)`).
typealias SettingsPane = SettingsPaneKind

/// What the Settings window asks the composition root to do; implemented by AppEnvironment.
@MainActor
protocol SettingsActions: AnyObject {
    /// "Báo lỗi..." (Support pane, safe-mode notice) and "Báo lỗi với ứng dụng này..." (PRD-R37): the bug report
    /// sheet, pre-filled with `bundle` when given.
    func reportProblemFromSettings(for bundle: BundleKey?)
    /// "Chẩn đoán..." (D26 entry, W2-C's diagnostics window).
    func openDiagnostics()
    /// PRD-R40: onboarding can be reopened from the About pane.
    func reopenOnboarding()
    /// ADR 0305: the tap suspends hotkeys while the recorder captures keys
    /// (`InputHostController.setRecorderActive(_:)`).
    func setHotkeyRecorderActive(_ active: Bool)
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// A new name for the System Settings style layout (W8-D), so the window opens once at its new default size
    /// instead of the frame saved for the old layout; from then on it is remembered again (PRD-R28).
    static let frameAutosaveName = "SettingsWindow.sidebar"
    static let defaultSize = NSSize(
        width: SettingsWindowLayout.defaultWidth, height: SettingsWindowLayout.defaultHeight)
    static let minimumSize = NSSize(
        width: SettingsWindowLayout.minimumWidth, height: SettingsWindowLayout.minimumHeight)

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
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        Self.configure(window)
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)  // PRD-R28: size and position remembered
        super.init(window: window)
        window.delegate = self
        window.selectPane = { [weak model] pane in model?.select(pane) }
        refreshTitle()
        observeLanguage()
    }

    /// Window traits of the layout, shared with the snapshot tool (scripts/snapshots): a normal window that does not
    /// float above other apps (PRD-R28), resizable down to about the size System Settings allows. Like System
    /// Settings, the content runs under a transparent, unified title bar (an empty toolbar gives it the taller
    /// height): the sidebar fills the window's full height with the window buttons inside it, and the pane's name
    /// sits in the title bar row (`SettingsRootView`). The window title stays set for VoiceOver and the Window menu,
    /// only hidden.
    static func configure(_ window: NSWindow) {
        window.level = .normal
        window.contentMinSize = minimumSize
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "SettingsWindow.toolbar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    /// Shows the window on `pane` (menu "Cài đặt...", "Viết tắt...", "Ủng hộ...", the URL scheme, PLT-R909).
    func show(_ pane: SettingsPane) {
        model.select(pane)
        present()
    }

    /// Command+, and a click on the Dock icon (PRD-R28): the window as the user left it, or General when it was closed.
    func showKeepingPane() {
        guard let window, window.isVisible || window.isMiniaturized else { return show(.general) }
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

/// Command+1 to Command+7 select the panes in sidebar order (PRD-R67), by the digit typed or, on layouts whose number
/// row types other characters, by the number row key. Only plain Command digits are taken; the
/// hotkey recorder sees every key first through its local monitor (ADR 0305), and a sheet has its own window.
final class SettingsWindow: NSWindow {
    var selectPane: (@MainActor (SettingsPaneKind) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let selectPane,
            let pane = SettingsPaneKind.forKeyEquivalent(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                modifierFlags: UInt64(event.modifierFlags.rawValue))
        {
            selectPane(pane)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Bundled data the window reads.
enum SettingsResources {
    /// `compat-matrix.json` copied into the bundle by the build (PRD-R38); nil when missing or invalid.
    static func bundledMatrix(bundle: Bundle = .main) -> MatrixDocument? {
        bundle.url(forResource: "compat-matrix", withExtension: "json").flatMap(MatrixLoader.load(contentsOf:))
    }
}
