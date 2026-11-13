// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The composition root's shell wiring: host events to the icon, HUD and notices (PRD-R10-R12, PLT-R399,
// PRD-R43), the menu model built on every open (PRD-R11, PRD-R13, PLT-R395, PLT-R721), and the menu actions.
// Workstream W2-A.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import InputHost
import SettingsStore
import ShellCore
import Synchronization

/// Delivers values from any thread to one main-actor handler (the settings store calls back on the utility
/// queue).
final class MainActorRelay<Value: Sendable>: Sendable {
    private let handler = Mutex<(@MainActor @Sendable (Value) -> Void)?>(nil)

    func connect(_ body: @escaping @MainActor @Sendable (Value) -> Void) { handler.withLock { $0 = body } }

    func send(_ value: Value) {
        let body = handler.withLock { $0 }
        DispatchQueue.main.async { MainActor.assumeIsolated { body?(value) } }
    }
}

extension AppEnvironment {
    /// PRD-R43: how long the "tap re-enabled" line stays after an instability notice.
    static let tapNoticeDuration: TimeInterval = 600
    /// PLT-R395, PLT-R721: checks run when the menu opens, at most this often.
    static let menuRefreshInterval: TimeInterval = 0.25

    // MARK: Host events

    func hostEvent(_ event: HostEvent) {
        switch event {
        case .stateChanged(let state):
            updateIcon()
            evaluateSelfCheck()
            noteSecureInputEpisode(state)
        case .modeChanged(let mode, let manual, _):
            updateIcon()
            // PRD-R12, D14: only manual switches, only with the indicator on.
            if SwitchIndicator.shouldShow(manual: manual, indicatorEnabled: settings.effective.showSwitchIndicator) {
                switchHUD?.show(mode)
            }
            onboarding?.modeChanged(mode)
        case .focusChanged:
            updateIcon()
        case .tapInstabilityNotice:
            tapReenabledUntil = Date().addingTimeInterval(Self.tapNoticeDuration)
        case .conflictsDetected(let conflicts):
            // Onboarding has its own conflicts screen (PRD-R40 screen 5); otherwise one notice per launch.
            guard onboarding == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.warnAboutConflicts(conflicts) }
        case .permissionsChanged(let status):
            onboarding?.permissionChanged(status)
            updateIcon()
        case .learningProposal:
            break  // open decision 8: visible and removable in Settings; nothing to show here
        }
    }

    /// PRD-R10 icon with a truthful VoiceOver label (PLT-R211).
    func updateIcon() {
        guard let statusItem else { return }
        let state = host.state
        let focus = host.currentFocus()
        let mode: TypingMode = if case .ready(let ready) = state { ready } else { focus.mode }
        let icon = StatusPresentation.iconState(
            state: state, mode: mode, ignored: frontmostRule(focus) == .ignore,
            capturing: StatusPresentation.isCapturing(diagnostics.capture, now: Date()))
        statusItem.show(icon, accessibilityLabelKey: StatusPresentation.accessibilityLabelKey(icon: icon, state: state))
    }

    private func warnAboutConflicts(_ conflicts: [ConflictingInput]) {
        let choice = CompositionAlerts.conflicts(
            conflicts, appName: brand.displayName, keyboardPane: paneNames().keyboard, localizer: language.localizer)
        switch choice {
        case .help: openSupport(.conflicts)
        case .openKeyboard: openPane(.keyboard)
        case .dismiss: break
        }
    }

    // MARK: Menu model (built on every open)

    /// PRD-R13: rebuilt when the menu opens; secure input and permissions are checked at that moment
    /// (PLT-R395, PLT-R721).
    func menuModel() -> MenuModel {
        refreshForMenu()
        let effective = settings.effective
        let localizer = language.localizer
        return MenuModel(
            statusLine: statusLine(), mode: displayedMode(),
            toggleHotkeyDisplay: HotkeyDisplay.string(
                for: effective.toggleHotkey, localizer: localizer),
            method: effective.typingMethod, frontmostApp: frontmostMenu(), appName: brand.displayName,
            updateCheckEnabled: updater?.canCheckForUpdates ?? false)
    }

    /// The status item also asks for the model when it only needs the app name for the icon's label, so the
    /// checks are skipped within `menuRefreshInterval` of the previous ones.
    private func refreshForMenu() {
        let now = Date()
        if let last = lastMenuRefresh, now.timeIntervalSince(last) < Self.menuRefreshInterval { return }
        lastMenuRefresh = now
        _ = host.refreshSecureInput()
        _ = host.refreshPermissions()
    }

    private func statusLine() -> StatusLine? {
        let state = host.state
        var holderHint: String?
        if case .paused(.secureInput(let holder?)) = state { holderHint = holder.hintKey }
        let recentlyReenabled = tapReenabledUntil.map { $0 > Date() } ?? false
        return StatusLine.forState(
            state, holderHintKey: holderHint, appName: brand.displayName, frontmostApp: frontmostStatus(),
            tapRecentlyReenabled: recentlyReenabled,
            onboardingCompleted: settings.user.onboarding.completedVersion != nil, safeMode: safeMode)
    }

    private func displayedMode() -> TypingMode {
        if case .ready(let mode) = host.state { return mode }
        return host.currentFocus().mode
    }

    private func frontmostMenu() -> MenuModel.FrontmostAppMenu? {
        let focus = host.currentFocus()
        guard let app = focus.app else { return nil }
        return MenuModel.FrontmostAppMenu(
            bundle: app.bundle, displayName: displayName(of: app), rule: frontmostRule(focus) ?? .remember)
    }

    /// PRD-R43 "App in Known limitation list": the frontmost app's matrix row.
    private func frontmostStatus() -> FrontmostAppStatus? {
        guard let app = host.currentFocus().app else { return nil }
        return FrontmostAppStatus(
            bundle: app.bundle, displayName: displayName(of: app), matrix: matrix, today: Date(),
            language: language.localizer.language, siteURL: brand.siteURL)
    }

    func frontmostRule(_ focus: FocusSnapshot) -> PerAppRule? {
        guard let bundle = focus.app?.bundle else { return nil }
        return settings.appModes.apps.first { $0.bundle == bundle }?.rule
    }

    private func displayName(of app: FocusedApp) -> String {
        NSRunningApplication(processIdentifier: app.pid)?.localizedName ?? app.bundle.rawValue
    }
}

// MARK: - Menu actions

extension AppEnvironment: StatusMenuActions {
    func setMode(_ mode: TypingMode) { host.setMode(mode, manual: true) }

    func setMethod(_ method: TypingMethod) {
        Task { await settingsStore.updateSettings { $0.typingMethod = .set(method) } }
    }

    func setRule(_ rule: PerAppRule, for bundle: BundleKey) {
        Task { await settingsStore.setAppRule(rule, for: bundle) }
    }

    /// The report flow. "Báo lỗi..." opens the bug report sheet with the last frontmost app (PRD-R47; the sheet
    /// falls back to the most recent other app while one of this app's windows has the focus); "Báo lỗi với ứng
    /// dụng này..." opens the misbehaves flow for that app (PLT-R1205). In safe mode the report items lead to the
    /// safe-mode choices first, so reset and exit stay reachable from the menu even while a host-state line hides
    /// the safe-mode line (PLT-R1009).
    func reportProblem(for bundle: BundleKey?) {
        let focused = host.currentFocus().app?.bundle
        switch DiagnosticsNavigation.destination(reportProblemFor: bundle, lastFrontmost: focused, safeMode: safeMode) {
        case .safeModeChoices: presentSafeMode()
        case .misbehaves(let app): diagnosticsController().startMisbehavesFlow(for: app)
        case .bugReport(let preselected): diagnosticsController().openBugReport(preselected: preselected)
        }
    }

    func openMacros() { settingsController()?.show(.macros) }
    func openSettings() { settingsController()?.show(.general) }
    func checkForUpdates() { updater?.checkForUpdates() }
    func openSupport() { settingsController()?.show(.aboutSupport) }

    func performStatusAction(_ action: StatusLine.Action) {
        switch action {
        case .grantPermission: presentOnboarding(startAt: .permission)
        case .resumeOnboarding: presentOnboarding(startAt: .permission)  // PRD-R41: resume at screen 2
        case .showHolderApp(let pid): NSRunningApplication(processIdentifier: pid)?.activate()
        case .secureInputHelp: openSupport(.secureInput)
        case .reportProblem: reportProblem(for: nil)  // the line's "Báo lỗi..." is the menu's (PRD-R43)
        case .learnMore(let url): NSWorkspace.shared.open(url)
        case .overrideTextFocus(let bundle): addTextFocusOverride(for: bundle)
        case .reopenApp: relaunchSelf()
        case .safeModeChoices: presentSafeMode()
        case .none: break
        }
    }

    /// PLT-R540: one click adds `requireTextFocus: never` to this app's one user override (a compatibility mode
    /// chosen in the Apps pane is kept, PLT-R520); it applies on the next keystroke.
    private func addTextFocusOverride(for bundle: BundleKey) {
        let strategy = host.currentFocus().decision.plan.strategy
        let commands = SettingsCommands(store: settingsStore)
        Task { _ = await commands.typeHereAnyway(for: bundle, strategy: strategy, at: Date()) }
    }

    func openSupport(_ topic: SupportLinks.Topic) {
        NSWorkspace.shared.open(SupportLinks.url(topic, siteURL: brand.siteURL, language: language.localizer.language))
    }

    /// ADR 0309 `failOpen(callbackStuck)` and PLT-R712: only a new process recovers.
    func relaunchSelf() {
        launchGuard.markSurvived()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Windows owned by other workstreams (created on demand)

    func settingsController() -> SettingsWindowController? {
        if let settingsWindow { return settingsWindow }
        guard let updater else { return nil }
        let host = self.host
        let controller = SettingsWindowController(
            store: settingsStore, language: language, updater: updater, loginItem: loginItem, brand: brand,
            inputSources: { host.enabledInputSources() }, layout: { host.currentLayoutTable() },
            keyValues: keyValues)
        controller.actions = self
        settingsWindow = controller
        return controller
    }

    func diagnosticsController() -> DiagnosticsWindowController {
        if let diagnosticsWindow { return diagnosticsWindow }
        let controller = DiagnosticsWindowController(
            language: language, report: { [unowned self] in diagnosticsReport() }, services: diagnosticsServices())
        diagnosticsWindow = controller
        return controller
    }

    // MARK: Safe mode (PLT-R1009)

    func presentSafeMode() {
        let store = settingsStore
        switch CompositionAlerts.safeMode(appName: brand.displayName, localizer: language.localizer) {
        case .reset:
            Task {
                await store.reset(.all(includeMacros: false))  // PRD-R26: macros only with their own checkbox
                await store.exitSafeMode()
            }
            safeMode = false
        case .exit:
            Task { await store.exitSafeMode() }
            safeMode = false
        case .report:
            diagnosticsController().openBugReport(preselected: host.currentFocus().app?.bundle)
        case .later:
            break
        }
    }
}
