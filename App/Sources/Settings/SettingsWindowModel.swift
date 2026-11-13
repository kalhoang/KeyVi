// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Main-actor state of the Settings window. Rules and copy live in ShellCore (SettingsCatalog, SettingsEdit,
// SettingsCommands and friends, tested there); this type connects them to the views, the store and the actions.
// Macros, Apps, transfer and hotkey parts are in the SettingsWindowModel+*.swift extensions.

import AppKit
import AppModel
import Combine
import CompatRules
import InputHost
import SettingsStore
import ShellCore

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published private(set) var state = SettingsState()
    @Published private(set) var selectedPane: SettingsPaneKind = .general
    @Published private(set) var advancedExpanded: Set<SettingsPaneKind> = []
    @Published private(set) var loginItem: LoginItemPresentation
    /// Short confirmation or error line under the current pane ("Đã lưu ...").
    @Published var statusMessage: String?

    // Sheets
    @Published var resetRequest: ResetRequest?
    @Published var exportSheet: ExportSheetState?
    @Published var importSummary: ImportSummary?
    @Published var importError: String?
    @Published var macroDraft: MacroDraft?
    @Published var macroDraftError: String?
    @Published var macroImport: MacroImportSession?
    @Published var macroImportError: String?
    @Published var macroToDelete: StoredMacro?
    @Published var appDetail: AppDetail?
    @Published var pendingPasteMode: BundleKey?
    @Published var showsLicences = false
    /// PRD-R53 note after switching from Beta back to Stable (the updater's `Updates` copy).
    @Published var channelNote = UpdateChannelNote()

    // Panes
    @Published var macroList = MacroListState(macros: [])
    @Published var wordListError: [UserWordList: String] = [:]
    /// Enabled input sources, read when the window is shown (not per render, PLT-R373).
    @Published private(set) var enabledInputSources: [InputSourceInfo] = []

    let brand: Brand
    let language: InterfaceLanguageModel
    let matrix: MatrixDocument?
    /// System Settings / System Preferences pane names of the running macOS (PRD-R64).
    let panes: SystemPaneNames
    let commands: SettingsCommands
    let updater: any UpdaterControlling
    let loginService: any LoginItemService
    let disclosures: AdvancedDisclosureMemory
    let readInputSources: @MainActor () -> [InputSourceInfo]
    /// Recorder capture lifecycle (ADR 0305): monitor and tap hotkey suspension end with the recording.
    let capture: HotkeyCaptureController
    weak var actions: (any SettingsActions)?
    let appIdentities = AppIdentityCache()
    /// Practice and word-list field text, observed only by those fields (not published through this model).
    let drafts = SettingsTextDrafts()
    /// Views observe this model; the language and the recorder it owns publish through it (ADR 0315).
    private var relays: [AnyCancellable] = []

    init(
        commands: SettingsCommands, language: InterfaceLanguageModel, updater: any UpdaterControlling,
        loginItem: any LoginItemService, brand: Brand, matrix: MatrixDocument?, panes: SystemPaneNames,
        inputSources: @escaping @MainActor () -> [InputSourceInfo], layout: @escaping @MainActor () -> LayoutTable?,
        disclosures: AdvancedDisclosureMemory
    ) {
        self.commands = commands
        self.language = language
        self.updater = updater
        loginService = loginItem
        self.brand = brand
        self.matrix = matrix
        self.panes = panes
        readInputSources = inputSources
        self.disclosures = disclosures
        self.loginItem = LoginItemPresentation(status: loginItem.status)
        advancedExpanded = Set(SettingsPaneKind.allCases.filter(disclosures.isExpanded))
        let relay = CaptureRelay()
        capture = HotkeyCaptureController(
            monitor: LocalKeyMonitor(),
            setHotkeysSuspended: { relay.model?.actions?.setHotkeyRecorderActive($0) },
            onFinished: { relay.model?.saveRecorded($1, for: $0) }, readLayout: layout)
        relay.model = self
        relays = [relayChanges(of: language), relayChanges(of: capture)]
        refreshSavedConflicts()
    }

    var localizer: Localizer { language.localizer }
    var settings: EffectiveSettings { state.effective }
    var appName: String { brand.displayName }

    // MARK: - State

    /// Fetches the store's state (on show) and the login item status (it can change in System Settings).
    func refresh() async {
        enabledInputSources = readInputSources()
        appIdentities.removeAll()
        apply(await commands.state())
        loginItem = LoginItemPresentation(status: loginService.status)
    }

    /// Takes the newest state: a reply that arrives after a newer `onChange` (lower generation) is ignored.
    func apply(_ newState: SettingsState) {
        guard newState.generation >= state.generation, newState != state else { return }
        state = newState
        macroList.replace(with: newState.macros)
        refreshSavedConflicts()
        language.select(newState.effective.interfaceLanguage)  // PRD-R63
    }

    /// Switching pane hides the recorder, so it also ends any capture (ADR 0305) and clears the status line.
    func select(_ pane: SettingsPaneKind) {
        guard pane != selectedPane else { return }
        cancelRecording()
        statusMessage = nil
        selectedPane = pane
    }

    // MARK: - Settings

    /// PRD-R27: applies at once. D19 to D21 reach the updater through the store: every publish re-applies the
    /// effective settings to it (`AppEnvironment.settingsChanged`), so each edit is written once.
    func edit(_ edit: SettingsEdit) {
        if case .interfaceLanguage(let value) = edit { language.select(value) }
        Task { apply(await commands.apply(edit)) }
    }

    func isAdvancedExpanded(_ pane: SettingsPaneKind) -> Bool { advancedExpanded.contains(pane) }

    /// PRD-R24: collapsed by default, remembered once expanded.
    func setAdvancedExpanded(_ expanded: Bool, for pane: SettingsPaneKind) {
        if expanded { advancedExpanded.insert(pane) } else { advancedExpanded.remove(pane) }
        disclosures.setExpanded(expanded, for: pane)
    }

    // MARK: - Login item (D17)

    /// SMAppService register / unregister runs off the main thread; the toggle shows the result when it returns.
    func setOpenAtLogin(_ enabled: Bool) {
        let service = loginService
        Task {
            loginItem = await Task.detached(priority: .userInitiated) {
                LoginItemControl.set(enabled, service: service)
            }.value
        }
    }

    func openLoginItemsSettings() { loginService.openSystemSettings() }

    /// The note and the button of the login item row. On macOS 12 both name System Preferences from the pane
    /// table in the macOS language (PRD-R64, ADR 0315).
    var loginItemText: LoginItemRowText {
        LoginItemRowText(localizer: localizer, appName: appName, panes: panes, presentation: loginItem)
    }

    // MARK: - Word lists (ENG-R860)

    func addWord(to list: UserWordList) {
        let draft = drafts[list]
        let current = Set(list.entries(in: settings))
        switch UserWordList.adding(draft, to: current) {
        case .added(let entries):
            wordListError[list] = nil
            drafts[list] = ""
            edit(list.edit(entries))
        case .invalid: wordListError[list] = localizer.string(SettingsText.listInvalid)
        case .duplicate: wordListError[list] = localizer.string(SettingsText.listDuplicate)
        }
    }

    func removeWord(_ word: String, from list: UserWordList) {
        edit(list.edit(Set(list.entries(in: settings)).subtracting([word])))
    }

    // MARK: - Layout binding (PLT-R373)

    var layoutBinding: LayoutBindingModel {
        LayoutBindingModel(binding: settings.layoutBinding, enabledSources: enabledInputSources)
    }

    // MARK: - Notices (PLT-R1006, PLT-R1007, PLT-R1009)

    var notices: [StoreNoticePresentation] {
        StoreNoticePresentation.all(state.notices, appName: appName, localizer: localizer)
    }

    func perform(_ action: StoreNoticePresentation.Action) {
        switch action {
        case .report: actions?.reportProblemFromSettings(for: nil)
        case .resetAll: resetRequest = ResetRequest(target: .all)
        case .dismiss, .useDefaults, .leaveSafeMode: Task { apply(await commands.perform(action)) }
        }
    }

    // MARK: - About & Support

    /// PRD-R53: leaving Beta says that nothing is downgraded.
    func selectChannel(_ channel: UpdateChannel) {
        channelNote.channelChanged(from: settings.updateChannel, to: channel)
        edit(.updateChannel(channel))
    }

    func checkForUpdates() { updater.checkForUpdates() }
    func reportProblem(for bundle: BundleKey? = nil) { actions?.reportProblemFromSettings(for: bundle) }
    func openDiagnostics() { actions?.openDiagnostics() }
    func reopenOnboarding() { actions?.reopenOnboarding() }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Lets the capture controller's closures reach the model without a retain cycle (the model owns the controller).
@MainActor
private final class CaptureRelay {
    weak var model: SettingsWindowModel?
}
