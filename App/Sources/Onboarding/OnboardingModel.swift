// SPDX-License-Identifier: GPL-3.0-or-later
//
// Main-actor state of the onboarding window. Navigation rules live in ShellCore's `OnboardingFlow`; screen copy
// in `PermissionScreenContent` and friends; this type only connects them to the views and the actions.

import AppKit
import AppModel
import Combine
import InputHost
import SettingsStore
import ShellCore

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var flow: OnboardingFlow
    @Published private(set) var inputs: OnboardingInputs
    @Published var method: TypingMethod
    @Published var practiceText = ""
    @Published var tryItText = "" {
        didSet { checklist?.textChanged(tryItText) }
    }
    @Published private(set) var checklist: TryItChecklist?
    @Published var openAtLogin = true  // D17, shown pre-checked
    /// False on macOS 12 (ADR 0315): the done screen shows how to add the app to Login Items by hand.
    let canOpenAtLogin: Bool
    @Published var showPermissionHelp = false
    /// PRD-R40 screen 6, PRD-R32: the import preview or the reason a file was refused (PRD-R43), shown as a sheet.
    @Published var macroImport: OnboardingImport?
    @Published var confirmPermissionReset = false
    /// PLT-R740, PRD-R43: the last reset failed; the help sheet says so with the remove-and-add-again steps.
    @Published private(set) var permissionResetFailed = false

    /// D11, shown on screen 4 and updated after an inline recording (PRD-R40).
    @Published private(set) var toggleHotkey: HotkeyBinding
    /// PRD-R40 screen 4: the inline recorder, with the Settings window's capture lifecycle (ADR 0305).
    let hotkeyCapture: HotkeyCaptureController

    let appName: String
    let panes: SystemPaneNames
    let language: InterfaceLanguageModel
    private weak var actions: (any OnboardingActions)?
    private let readInputs: @MainActor () -> OnboardingInputs
    private var currentMode: TypingMode
    var onFinish: (@MainActor () -> Void)?
    /// Views observe this model; the language and the recorder it owns publish through it (ADR 0315).
    private var relays: [AnyCancellable] = []

    init(
        flow: OnboardingFlow, language: InterfaceLanguageModel, actions: any OnboardingActions,
        inputs: @escaping @MainActor () -> OnboardingInputs, appName: String, panes: SystemPaneNames,
        method: TypingMethod, mode: TypingMode, toggleHotkey: HotkeyBinding
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
        self.toggleHotkey = toggleHotkey
        canOpenAtLogin = actions.canOpenAtLogin
        let relay = OnboardingCaptureRelay()
        hotkeyCapture = HotkeyCaptureController(
            monitor: LocalKeyMonitor(),
            setHotkeysSuspended: { relay.model?.actions?.setHotkeyRecorderActive($0) },
            onFinished: { _, binding in relay.model?.saveToggleHotkey(binding) },
            readLayout: { relay.model?.actions?.currentLayout() })
        relay.model = self
        relays = [relayChanges(of: language), relayChanges(of: hotkeyCapture)]
    }

    var localizer: Localizer { language.localizer }

    /// PRD-R40 screen 8 on macOS 12: where to add the app to Login Items, with the macOS names (PRD-R64).
    var openAtLoginManualText: String {
        localizer.format(
            OnboardingText.doneOpenAtLoginManual, appName, panes.systemSettings, panes.usersGroups, panes.loginItems)
    }

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
            if canOpenAtLogin { actions?.setOpenAtLogin(openAtLogin) }
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
    /// PRD-R40 screen 4 "Đổi phím chuyển": records inline in this window.
    func startHotkeyRecording() { hotkeyCapture.start(.toggleMode) }
    func cancelHotkeyRecording() { hotkeyCapture.cancel() }
    func interruptHotkeyRecording() { hotkeyCapture.interrupt() }
    var isRecordingHotkey: Bool { hotkeyCapture.recordingRole == .toggleMode }

    /// Live keys, a rejection reason or the PRD-R16 conflict warning under the recorder.
    var hotkeyStatus: String? {
        hotkeyCapture.session.flatMap {
            HotkeyRecorderText.status($0.state, role: .toggleMode, appName: appName, localizer: localizer)
        }
    }

    /// "Dùng mặc định" (Control + Shift, D11).
    func useDefaultToggleHotkey() {
        hotkeyCapture.cancel()
        saveToggleHotkey(.defaultToggle)
    }

    private func saveToggleHotkey(_ binding: HotkeyBinding) {
        toggleHotkey = binding
        actions?.saveToggleHotkey(binding)
    }
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
        hotkeyCapture.cancel()
        actions?.onboardingClosed(completed: flow.isFinished)
    }

    func modeChanged(_ mode: TypingMode) {
        currentMode = mode
        checklist?.modeChanged(to: mode)
    }

    // MARK: - Private

    private func move(_ transition: (inout OnboardingFlow, OnboardingInputs) -> Void) {
        hotkeyCapture.cancel()  // a recorder off screen never keeps the tap's hotkeys suspended (ADR 0305)
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

/// Lets the capture controller's closures reach the model without a retain cycle.
@MainActor
private final class OnboardingCaptureRelay {
    weak var model: OnboardingModel?
}
