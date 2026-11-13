// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding wiring of the composition root (PRD-R40-R42, PLT-R701-R712, PLT-R740) and the first-launch-after-
// update self-check (QA-R42). Workstream W2-A.

import AppKit
import AppModel
import InputHost
import SettingsStore
import ShellCore

extension AppEnvironment {
    /// Full onboarding (`startAt == nil`), the resume and "permission lost" variants at the permission screen
    /// (PRD-R41, PRD-R42). One window at a time; permissions are polled every second while it is open (PLT-R711).
    func presentOnboarding(startAt screen: OnboardingScreen?) {
        if let onboarding {
            onboarding.showWindow(nil)
            NSApp.activate()
            return
        }
        let inputs = onboardingInputs()
        let flow = screen.map { OnboardingFlow(inputs: inputs, startAt: $0) } ?? OnboardingFlow(inputs: inputs)
        let controller = OnboardingWindowController(
            flow: flow, language: language, actions: self, inputs: { [unowned self] in onboardingInputs() },
            appName: brand.displayName, panes: paneNames(), method: settings.effective.typingMethod,
            mode: host.currentFocus().mode)
        onboarding = controller
        host.setPermissionFastPolling(true)
        controller.showWindow(nil)
        NSApp.activate()
    }

    func onboardingInputs() -> OnboardingInputs {
        let context = host.reportContext()
        let completedBefore = settings.user.onboarding.completedVersion != nil
        return OnboardingInputs(
            permission: context.permissions, conflicts: context.conflicts, importCandidates: [],
            permissionLostAfterCompletion: completedBefore && !OnboardingFlow.isGranted(context.permissions))
    }

    /// PRD-R64: pane names of the running macOS in the system language (they are system UI, not app copy).
    func paneNames() -> SystemPaneNames {
        let language = Locale.preferredLanguages.first ?? "en"
        if let table = paneTable {
            return table.names(macOS: InputHostController.macOSVersion, systemLanguage: language)
        }
        // SystemPanes.json ships in the bundle and is tested; this only guards a broken build.
        return SystemPaneNames(
            systemSettings: "System Settings", privacySecurity: "Privacy & Security", accessibility: "Accessibility",
            inputMonitoring: "Input Monitoring", keyboard: "Keyboard", textReplacements: "Text Replacements")
    }

    func openPane(_ pane: SystemPane) {
        guard let url = paneTable?.deepLink(pane, macOS: InputHostController.macOSVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    /// QA-R42: after an update, a lost or stale permission or a tap that cannot be created opens the permission
    /// screen (PRD-R42) instead of failing silently. Decided once, on the first state after `starting`.
    func evaluateSelfCheck() {
        guard selfCheckPending else { return }
        let health = host.reportContext().permissions.health
        switch UpdateSelfCheck.verdict(state: host.state, permissions: health) {
        case .pending: return
        case .passed: selfCheckPending = false
        case .showPermissionScreen:
            selfCheckPending = false
            presentOnboarding(startAt: .permission)
        }
    }
}

extension AppEnvironment: OnboardingActions {
    /// PLT-R701, PLT-R704: Accessibility only, through the deep link of SystemPanes.json; the system prompt
    /// adds the app to the list so the user only flips the switch.
    func openPermissionPane() {
        SystemPermissionProbe().promptForAccessibility()
        openPane(.accessibility)
    }

    /// PLT-R702: only when macOS demands Input Monitoring for the tap.
    func openInputMonitoringPane() {
        _ = SystemPermissionProbe().requestListenEventAccess()
        openPane(.inputMonitoring)
    }

    /// PLT-R740: after the user confirmed in the sheet; never automatic, never without the own bundle ID.
    func resetPermission() {
        try? TCCPermissionResetter(ownBundleIdentifier: brand.bundleIdentifier)
            .resetAccessibility(bundleIdentifier: brand.bundleIdentifier)
        _ = host.refreshPermissions()
    }

    func relaunch() { relaunchSelf() }

    func setTypingMethod(_ method: TypingMethod) { setMethod(method) }

    /// PRD-R40 screen 4 "Đổi phím chuyển": the recorder lives in Settings (W2-B owns it).
    func openHotkeyRecorder() { presentHotkeyRecorder() }

    /// PRD-R40 screen 5: a help page; the app never quits or changes the other app.
    func openConflictHelp(_ conflict: ConflictingInput) { openSupport(.conflicts) }

    func openKeyboardPane() { openPane(.keyboard) }

    /// PLT-R205: `SMAppService.mainApp`; the toggle state is the system's (D17).
    func setOpenAtLogin(_ enabled: Bool) {
        if enabled { try? loginItem.register() } else { try? loginItem.unregister() }
    }

    /// PRD-R40 screen 6, PRD-R32: macros from the chosen file, the user's own macros kept for duplicates.
    func importMacros(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let store = settingsStore
        let fileExtension = url.pathExtension
        Task {
            let existing = await store.state.macros
            guard
                let merged = OnboardingMacroImport.merged(data: data, fileExtension: fileExtension, existing: existing)
            else { return }
            await store.replaceMacros(merged)
        }
    }

    func complete() {
        let version = brand.version
        Task { await settingsStore.updateSettings { $0.onboarding.completedVersion = version } }
    }

    /// PRD-R41: closing early leaves the "resume" status line; fast polling stops with the window.
    func onboardingClosed(completed: Bool) {
        host.setPermissionFastPolling(false)
        onboarding = nil
        updateIcon()
    }
}

extension AppEnvironment: HotkeyRecorderPresenting {
    func presentHotkeyRecorder() { settingsController()?.show(.general) }
}
