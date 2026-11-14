// SPDX-License-Identifier: GPL-3.0-or-later
//
// Onboarding wiring of the composition root (PRD-R40-R42, PLT-R701-R712, PLT-R740) and the first-launch-after-
// update self-check (QA-R42). Workstream W2-A.

import AppKit
import AppModel
import Diagnostics
import InputHost
import SettingsStore
import ShellCore

extension AppEnvironment {
    /// Full onboarding (`startAt == nil`), the resume and "permission lost" variants at the permission screen
    /// (PRD-R41, PRD-R42). One window at a time; permissions are polled every second while it is open (PLT-R711).
    func presentOnboarding(startAt screen: OnboardingScreen?) {
        if let onboarding {
            onboarding.showWindow(nil)
            NSApp.bringToFront()
            return
        }
        let inputs = onboardingInputs()
        let flow = screen.map { OnboardingFlow(inputs: inputs, startAt: $0) } ?? OnboardingFlow(inputs: inputs)
        let controller = OnboardingWindowController(
            flow: flow, language: language, actions: self, inputs: { [unowned self] in onboardingInputs() },
            appName: brand.displayName, panes: paneNames(), method: settings.effective.typingMethod,
            mode: host.currentFocus().mode, toggleHotkey: settings.effective.toggleHotkey)
        onboarding = controller
        host.setPermissionFastPolling(true)
        controller.showWindow(nil)
        NSApp.bringToFront()
    }

    /// Read on presentation, on every screen change, on "Kiểm tra lại" (PRD-R40 screen 5) and when the
    /// permission status changes: all user-paced, so the conflict list is rescanned each time.
    func onboardingInputs() -> OnboardingInputs {
        host.rescanConflicts()
        let context = host.reportContext()
        importCandidates = Self.importCandidates(importCandidates, adding: context.conflicts)
        let completedBefore = settings.user.onboarding.completedVersion != nil
        return OnboardingInputs(
            permission: context.permissions, conflicts: context.conflicts, importCandidates: importCandidates,
            permissionLostAfterCompletion: completedBefore && !OnboardingFlow.isGranted(context.permissions))
    }

    /// PRD-R40 screen 6: a running competitor app (the rules' conflicting input apps) is a known import source.
    /// Nothing is read here; the import runs only after the explicit "Chọn file..." click (PRD-R69).
    static func importCandidates(_ seen: [ImportCandidate], adding conflicts: [ConflictingInput]) -> [ImportCandidate] {
        let known = Set(seen.compactMap(\.bundle))
        let added = conflicts.compactMap { conflict -> ImportCandidate? in
            guard case .runningApp(let bundle, let name) = conflict, !known.contains(bundle) else { return nil }
            return ImportCandidate(appName: name, bundle: bundle)
        }
        return seen + added
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
            inputMonitoring: "Input Monitoring", keyboard: "Keyboard", textReplacements: "Text Replacements",
            usersGroups: "General", loginItems: "Login Items")
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
    /// PLT-R701, PLT-R704: the Accessibility pane (Device Control and Data Access on macOS 27) through the deep
    /// link of SystemPanes.json; the system prompt adds the app to the list so the user only flips the switch.
    func openPermissionPane() {
        SystemPermissionProbe().promptForAccessibility()
        openPane(.accessibility)
    }

    /// PLT-R702: only when the tap needs Input Monitoring; the primary button of screen 2 once it is the first
    /// permission still missing. A repeated request returns the earlier answer without a new prompt.
    func openInputMonitoringPane() {
        _ = SystemPermissionProbe().requestListenEventAccess()
        openPane(.inputMonitoring)
    }

    /// PLT-R702: called once when screen 2 first shows Input Monitoring as needed, so macOS lists the app and shows
    /// its prompt before the user goes looking for the switch.
    func requestInputMonitoringAccess() {
        _ = SystemPermissionProbe().requestListenEventAccess()
    }

    /// PLT-R740: after the user confirmed in the sheet; never automatic, never without the own bundle ID. After a
    /// reset macOS is asked to prompt again, which adds the app back to the list; a failure is logged and the
    /// sheet says so (PRD-R43).
    func resetPermission() -> PermissionReset.Outcome {
        let outcome = PermissionReset.run(
            TCCPermissionResetter(ownBundleIdentifier: brand.bundleIdentifier),
            bundleIdentifier: brand.bundleIdentifier)
        switch outcome {
        case .reset: SystemPermissionProbe().promptForAccessibility()
        case .failed:
            diagnostics.logger.log(
                .note("Accessibility permission reset failed", category: .permissions), level: .error)
        }
        _ = host.refreshPermissions()
        return outcome
    }

    func relaunch() { relaunchSelf() }

    func setTypingMethod(_ method: TypingMethod) { setMethod(method) }

    /// PRD-R40 screen 4 "Đổi phím chuyển", recorded inline: an explicit D11 choice (PRD-R6).
    func saveToggleHotkey(_ binding: HotkeyBinding) {
        let commands = SettingsCommands(store: settingsStore)
        Task { _ = await commands.apply(.toggleHotkey(binding)) }
    }

    func currentLayout() -> LayoutTable? { host.currentLayoutTable() }

    /// PRD-R40 screen 5: a help page; the app never quits or changes the other app.
    func openConflictHelp(_ conflict: ConflictingInput) { openSupport(.conflicts) }

    func openKeyboardPane() { openPane(.keyboard) }

    /// PLT-R205: `SMAppService.mainApp`; the toggle state is the system's (D17).
    func setOpenAtLogin(_ enabled: Bool) {
        if enabled { try? loginItem.register() } else { try? loginItem.unregister() }
    }

    /// False on macOS 12 (ADR 0315): the done screen explains how to add the app by hand instead.
    var canOpenAtLogin: Bool { loginItem.status != .unavailable }

    /// PRD-R40 screen 6, PRD-R32: the import preview compares the file with these.
    func currentMacros() async -> [StoredMacro] { await settingsStore.state.macros }

    /// The list the user confirmed in the preview (duplicates resolved as chosen, ENG-R1101 NFC).
    func saveImportedMacros(_ macros: [StoredMacro]) {
        let commands = SettingsCommands(store: settingsStore)
        Task { _ = await commands.saveMacros(macros) }
    }

    func complete() {
        let version = brand.version
        Task { await settingsStore.updateSettings { $0.onboarding.completedVersion = version } }
    }

    /// PRD-R41: closing early leaves the "resume" status line; fast polling stops with the window.
    func onboardingClosed(completed: Bool) {
        host.setPermissionFastPolling(false)
        onboarding = nil
        importCandidates = []
        updateIcon()
    }
}

/// What the Settings window asks of the composition root (W2-B).
extension AppEnvironment: SettingsActions {
    // `reportProblemFromSettings(for:)` is next to the menu's `reportProblem(for:)` (AppEnvironment+Shell).

    func openDiagnostics() { diagnosticsController().showReport() }

    /// PRD-R40: onboarding reopened from the About pane starts at screen 1.
    func reopenOnboarding() { presentOnboarding(startAt: nil) }

    /// ADR 0305, PRD-R15: the tap suspends its hotkeys while the recorder captures keys.
    func setHotkeyRecorderActive(_ active: Bool) { host.setRecorderActive(active) }
}
