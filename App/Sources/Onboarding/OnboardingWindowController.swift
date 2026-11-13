// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding window, 640 x 480 pt, centred, not floating, eight screens driven by ShellCore's OnboardingFlow
// (PRD-R40-R42). Workstream W1-G.

import AppKit
import AppModel
import Combine
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

@MainActor
protocol OnboardingActions: AnyObject {
    func openPermissionPane()  // deep link from SystemPanes.json (PLT-R704)
    func openInputMonitoringPane()  // PLT-R702, only when macOS demands Input Monitoring
    func resetPermission() -> PermissionReset.Outcome  // PLT-R740, after confirmation
    func relaunch()  // PLT-R712
    func setTypingMethod(_ method: TypingMethod)
    /// PRD-R40 screen 4 "Đổi phím chuyển", recorded inline: the tap's hotkeys are suspended while the recorder
    /// captures keys (ADR 0305), the recorded binding is saved as the toggle key (D11, PRD-R6 explicit).
    func setHotkeyRecorderActive(_ active: Bool)
    func saveToggleHotkey(_ binding: HotkeyBinding)
    func currentLayout() -> LayoutTable?
    func openConflictHelp(_ conflict: ConflictingInput)  // PRD-R40 screen 5 help page (never quits other apps)
    func openKeyboardPane()  // PRD-R40 screen 5, built-in Vietnamese source
    func setOpenAtLogin(_ enabled: Bool)
    /// False on macOS 12, where the app cannot add itself to the login items (ADR 0315).
    var canOpenAtLogin: Bool { get }
    /// PRD-R40 screen 6, PRD-R32: the user's macros, for the import preview's duplicates.
    func currentMacros() async -> [StoredMacro]
    /// The merged list after the user confirmed the preview.
    func saveImportedMacros(_ macros: [StoredMacro])
    func complete()
    /// The window closed; `completed == false` means before the last screen (PRD-R41: the status line then offers
    /// to resume at screen 2, and fast permission polling stops).
    func onboardingClosed(completed: Bool)
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 640, height: 480)

    private let model: OnboardingModel
    private var languageObservation: AnyCancellable?

    required init?(coder: NSCoder) { nil }

    /// `startAt: .permission` for the "permission lost" variant (PRD-R42) and for resuming (PRD-R41).
    /// `appName` comes from `Brand`; `panes` from `SystemPaneTable` for the running macOS and its language
    /// (PRD-R64); `method` and `mode` are the current typing method and VI/EN mode.
    init(
        flow: OnboardingFlow, language: InterfaceLanguageModel, actions: any OnboardingActions,
        inputs: @escaping @MainActor () -> OnboardingInputs, appName: String, panes: SystemPaneNames,
        method: TypingMethod = .telex, mode: TypingMode = .vietnamese, toggleHotkey: HotkeyBinding = .defaultToggle
    ) {
        model = OnboardingModel(
            flow: flow, language: language, actions: actions, inputs: inputs, appName: appName, panes: panes,
            method: method, mode: mode, toggleHotkey: toggleHotkey)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.level = .normal  // PRD-R40: not floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingRootView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.close() }
        refreshTitle()
        observeLanguage()
    }

    /// Called by the permission monitor (1 s polling while visible, PLT-R711).
    func permissionChanged(_ status: PermissionStatus) {
        model.permissionChanged(status)
    }

    /// VI/EN changes feed the try-it checklist ("press the toggle hotkey once and back", PRD-R40 screen 7).
    func modeChanged(_ mode: TypingMode) {
        model.modeChanged(mode)
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
    }

    /// ADR 0305: another window or app took the keyboard, so the recorder stops taking key events.
    func windowDidResignKey(_ notification: Notification) {
        model.interruptHotkeyRecording()
    }

    /// PRD-R63: the window title follows a language change; SwiftUI content re-renders by itself.
    private func refreshTitle() {
        window?.title = model.localizer.format(OnboardingText.windowTitle, model.appName)
    }

    private func observeLanguage() {
        languageObservation = model.language.afterChange { [weak self] in self?.refreshTitle() }
    }
}
