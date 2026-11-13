// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Main-actor state of the onboarding window. Navigation rules live in ShellCore's `OnboardingFlow`; screen copy
// in `PermissionScreenContent` and friends; this type only connects them to the views and the actions.

import AppKit
import AppModel
import InputHost
import Observation
import SettingsStore
import ShellCore

@MainActor
@Observable
final class OnboardingModel {
    private(set) var flow: OnboardingFlow
    private(set) var inputs: OnboardingInputs
    var method: TypingMethod
    var practiceText = ""
    var tryItText = "" {
        didSet { checklist?.textChanged(tryItText) }
    }
    private(set) var checklist: TryItChecklist?
    var openAtLogin = true  // D17, shown pre-checked
    var showPermissionHelp = false
    /// PRD-R40 screen 6, PRD-R32: the import preview or the reason a file was refused (PRD-R43), shown as a sheet.
    var macroImport: OnboardingImport?
    var confirmPermissionReset = false
    /// PLT-R740, PRD-R43: the last reset failed; the help sheet says so with the remove-and-add-again steps.
    private(set) var permissionResetFailed = false

    let appName: String
    let panes: SystemPaneNames
    let language: InterfaceLanguageModel
    @ObservationIgnored private weak var actions: (any OnboardingActions)?
    @ObservationIgnored private let readInputs: @MainActor () -> OnboardingInputs
    @ObservationIgnored private var currentMode: TypingMode
    @ObservationIgnored var onFinish: (@MainActor () -> Void)?

    init(
        flow: OnboardingFlow, language: InterfaceLanguageModel, actions: any OnboardingActions,
        inputs: @escaping @MainActor () -> OnboardingInputs, appName: String, panes: SystemPaneNames,
        method: TypingMethod, mode: TypingMode
    ) {
        self.flow = flow
        self.language = language
        self.actions = actions
        readInputs = inputs
        self.inputs = inputs()
        self.appName = appName
        self.panes = panes
        self.method = method
        currentMode = mode
    }

    var localizer: Localizer { language.localizer }

    var permissionContent: PermissionScreenContent {
        PermissionScreenContent(
            localizer: localizer, appName: appName, panes: panes, status: inputs.permission,
            permissionLost: flow.permissionOnly)
    }

    var helpContent: PermissionHelpContent {
        PermissionHelpContent(localizer: localizer, appName: appName, panes: panes)
    }

    // MARK: - Footer

    var primaryTitle: String {
        switch flow.screen {
        case .welcome: localizer.string(OnboardingText.welcomeStart)
        case .permission:
            if !flow.permissionGranted {
                permissionContent.openPaneButton
            } else {
                localizer.string(flow.permissionOnly ? CommonText.close : CommonText.continue)
            }
        case .typingMethod, .switching, .conflicts: localizer.string(CommonText.continue)
        case .importFrom: localizer.string(OnboardingText.importChooseFile)
        case .tryIt: localizer.string(OnboardingText.tryItDone)
        case .done: localizer.string(OnboardingText.doneStart)
        }
    }

    var primaryControl: OnboardingControl {
        switch flow.screen {
        case .permission where !flow.permissionGranted: .openPermissionPane
        case .importFrom: .chooseImportFile
        default: .primary
        }
    }

    /// PRD-R40: "Bỏ qua" everywhere except the permission screen; the last screen finishes instead.
    var showsSkip: Bool { flow.canSkip && flow.screen != .done }
    var skipTitle: String {
        flow.screen == .importFrom ? localizer.string(OnboardingText.importLater) : localizer.string(CommonText.skip)
    }
    var skipControl: OnboardingControl { flow.screen == .importFrom ? .importLater : .skip }

    func primary() {
        switch flow.screen {
        case .permission where !flow.permissionGranted: actions?.openPermissionPane()
        case .importFrom: chooseImportFile()
        case .done:
            actions?.setOpenAtLogin(openAtLogin)
            actions?.complete()
            move { $0.next(inputs: $1) }
        default: move { $0.next(inputs: $1) }
        }
    }

    func back() { move { flow, _ in flow.back() } }
    func skip() { move { $0.skip(inputs: $1) } }

    // MARK: - Screen actions

    func select(_ method: TypingMethod) {
        self.method = method
        actions?.setTypingMethod(method)
    }

    func openInputMonitoringPane() { actions?.openInputMonitoringPane() }
    func relaunch() { actions?.relaunch() }
    func openHotkeyRecorder() { actions?.openHotkeyRecorder() }
    func openConflictHelp(_ conflict: ConflictingInput) { actions?.openConflictHelp(conflict) }
    func openKeyboardPane() { actions?.openKeyboardPane() }

    /// PLT-R740: runs only after the user confirmed in the sheet.
    func resetPermission() {
        confirmPermissionReset = false
        permissionResetFailed = actions?.resetPermission() == .failed
    }

    /// "Kiểm tra lại" on the conflicts screen: moves on once nothing conflicts any more.
    func checkConflictsAgain() {
        inputs = readInputs()
        if inputs.conflicts.isEmpty { move { $0.next(inputs: $1) } }
    }

    /// PLT-R711: called on every permission poll while the window is visible.
    func permissionChanged(_ status: PermissionStatus) {
        inputs = readInputs()
        inputs.permission = status
        flow.permissionChanged(status, inputs: inputs)
        enteredScreen()
    }

    /// PRD-R41: closing before the end leaves the slashed icon and a "resume" status line (App side).
    func windowClosed() {
        actions?.onboardingClosed(completed: flow.isFinished)
    }

    func modeChanged(_ mode: TypingMode) {
        currentMode = mode
        checklist?.modeChanged(to: mode)
    }

    // MARK: - Private

    private func move(_ transition: (inout OnboardingFlow, OnboardingInputs) -> Void) {
        inputs = readInputs()
        transition(&flow, inputs)
        enteredScreen()
    }

    private func enteredScreen() {
        if flow.isFinished {
            onFinish?()
            return
        }
        if flow.screen == .tryIt, checklist == nil {
            checklist = TryItChecklist(
                vietnameseTarget: localizer.string(OnboardingText.tryItTargetVietnamese),
                englishTarget: localizer.string(OnboardingText.tryItTargetEnglish), startMode: currentMode)
        }
    }

    /// PRD-R40 screen 6 / PRD-R69: a file only from the user's explicit choice. The Macros pane's preview comes
    /// first (PRD-R32); a refused file is explained and the flow stays here (PRD-R43 "Import file invalid").
    func chooseImportFile() {
        FilePanels.open(types: FilePanels.macroTypes) { [weak self] url in
            Task { await self?.openImportFile(url) }
        }
    }

    private func openImportFile(_ url: URL) async {
        let data = await FilePanels.readOffMain(url, maxBytes: MacroImporter.maxFileBytes)
        let existing = await actions?.currentMacros() ?? []
        macroImport = OnboardingImport.opening(
            data, fileExtension: url.pathExtension, existing: existing, localizer: localizer)
    }

    /// "Nhập": merges with the duplicate choice, then moves on; a failed merge keeps the sheet with its reason.
    func confirmImport() async {
        guard var step = macroImport else { return }
        let existing = await actions?.currentMacros() ?? []
        let merged = step.confirm(existing: existing, localizer: localizer)
        macroImport = step
        guard let merged, step.advancesFlow else { return }
        actions?.saveImportedMacros(merged)
        macroImport = nil
        move { $0.next(inputs: $1) }
    }

    /// "Hủy": nothing is imported and the flow stays on screen 6 ("Để sau" moves on).
    func cancelImport() { macroImport = nil }
}
