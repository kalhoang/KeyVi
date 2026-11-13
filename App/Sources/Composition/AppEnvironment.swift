// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Composition root (workstream W2-A). Builds every production service once, wires AppCore modules together
// and owns the window controllers. Main actor only. The launch order is `LaunchSequence` (InputHost
// Integration, tested with fakes); the shell and onboarding wiring live in `AppEnvironment+*.swift`.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import Injection
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

@MainActor
final class AppEnvironment {
    let brand: Brand
    let language: InterfaceLanguageModel
    let settingsStore: SettingsStore
    let host: InputHostController
    /// Created by the launch's shell step (PRD-R9), after the location check and the settings load.
    private(set) var statusItem: StatusItemController?
    /// Created by the launch's last step (PLT-R1101).
    private(set) var updater: UpdaterController?

    let paths: StoragePaths
    let utility: DispatchSerialQueue
    let keyValues = UserDefaultsKeyValueStore()
    let launchGuard: LaunchGuard
    let diagnostics: DiagnosticsWiring
    let loginItem = SMAppServiceLoginItem()
    let settingsChanges = MainActorRelay<SettingsState>()
    var settings = SettingsState()
    var safeMode = false
    var launch: LaunchSequence?
    var switchHUD: SwitchHUDController?
    var onboarding: OnboardingWindowController?
    /// PRD-R40 screen 6: competitor apps seen running while onboarding is open, kept after the user quits them on
    /// screen 5 so the import offer still appears.
    var importCandidates: [ImportCandidate] = []
    var settingsWindow: SettingsWindowController?
    var diagnosticsWindow: DiagnosticsWindowController?
    lazy var paneTable: SystemPaneTable? = Self.loadPaneTable()
    /// QA-R42: the first launch after an update checks the host once it left `starting`.
    var selfCheckPending = false
    /// PRD-R43: the "tap re-enabled" line stays in the status menu for a while after an instability notice.
    var tapReenabledUntil: Date?
    var lastMenuRefresh: Date?

    /// Launch order (S1 target 300 ms to tap active): LaunchGuard -> AppLocationCheck (move offer before any
    /// permission request, PLT-R710) -> LegacyStorageMigrator -> SettingsStore.load ->
    /// RulesLoader.load(compat-rules.json) -> InputHostController.start -> StatusItemController -> onboarding if
    /// not completed (PRD-R40, PRD-R42) -> UpdaterController.start.
    init(bundle: Bundle) {
        brand = Brand.from(bundle)
        language = InterfaceLanguageModel(language: DefaultSettings.v1.interfaceLanguage, appBundle: bundle)
        paths = StoragePaths(folder: brand.storageFolderName)
        utility = DispatchSerialQueue(label: brand.slug + ".utility", qos: .utility)
        launchGuard = LaunchGuard(store: keyValues)
        diagnostics = DiagnosticsWiring(
            paths: paths, subsystem: brand.bundleIdentifier, utility: utility, defaults: .standard)
        let relay = settingsChanges
        settingsStore = SettingsStore(
            location: StorageLocation(directory: paths.applicationSupport), fileSystem: LocalFileSystem(),
            wallClock: SystemWallClock(), writtenBy: brand.version, queue: utility, launchGuard: launchGuard,
            onChange: { relay.send($0) })
        host = InputHostController(
            dependencies: .production(diagnostics: diagnostics, keyValues: keyValues, utility: utility),
            settingsStore: settingsStore)
        settingsChanges.connect { [weak self] state in self?.settingsChanged(state) }
        host.onEvent = { [weak self] event in self?.hostEvent(event) }
    }

    func start() {
        diagnostics.startMaintenance()
        diagnostics.logger.log(.lifecycle(.launched(appIdentity)), level: .notice)
        let sequence = LaunchSequence(
            launchGuard: launchGuard, appVersion: bundleVersion, wallClock: SystemWallClock(),
            scheduler: DispatchTimerScheduler(queue: utility), steps: self)
        launch = sequence
        Task {
            switch await sequence.run() {
            case .running(let safeMode): self.launched(safeMode: safeMode)
            case .relocating, .quit: NSApp.terminate(nil)
            }
        }
    }

    /// Quit: flush settings (PLT-R1003), stop the host (tap removed), let Sparkle install on quit (D20).
    func terminate(completion: @escaping @MainActor () -> Void) {
        diagnostics.logger.log(.lifecycle(.terminating), level: .notice)
        launch?.terminate()
        host.stop()
        let store = settingsStore
        let diagnostics = self.diagnostics
        Task {
            await store.flush()
            diagnostics.flush()
            completion()
        }
    }

    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func handle(url: URL) {
        guard URLSchemeRouter.route(url, scheme: brand.urlScheme) == .openSettings else { return }
        openSettings()
    }

    // MARK: Launch results

    /// `CFBundleShortVersionString` plus the build, so an update clears a crash loop (W1-B request).
    var bundleVersion: String { LaunchSequence.versionString(short: brand.version, build: brand.build) }

    var appIdentity: AppIdentity {
        AppIdentity(
            displayName: brand.displayName, slug: brand.slug, bundleIdentifier: brand.bundleIdentifier,
            version: brand.version, build: brand.build, channel: settings.effective.updateChannel)
    }

    private func launched(safeMode: Bool) {
        self.safeMode = safeMode
        if safeMode {
            diagnostics.logger.log(
                .lifecycle(.safeModeEntered(recentCrashes: launchGuard.recentCrashes)), level: .error)
            diagnostics.health.record(HealthEvent(kind: .safeModeEntered, at: Date()))
            DispatchQueue.main.async { [weak self] in self?.presentSafeMode() }
        }
        selfCheckPending = UpdateSelfCheck(store: keyValues).noteLaunch(version: bundleVersion) == .versionChanged
        evaluateSelfCheck()
    }

    /// Every settings change: the host (engines, rules, focus), the language, the shell and the updater.
    func settingsChanged(_ state: SettingsState) {
        settings = state
        safeMode = state.safeMode  // PLT-R1009: the store decides; leaving safe mode reloads the files
        host.apply(settings: state)
        language.select(state.effective.interfaceLanguage)
        statusItem?.setClickToToggle(state.effective.clickIconToToggle)
        applyUpdaterSettings()
        updateIcon()
    }

    func applyUpdaterSettings() {
        guard let updater else { return }
        let effective = settings.effective
        updater.automaticallyChecksForUpdates = effective.automaticallyCheckForUpdates
        updater.automaticallyDownloadsUpdates = effective.automaticallyInstallUpdates
        updater.channel = effective.updateChannel == .beta ? .beta : .stable
    }

    private static func loadPaneTable() -> SystemPaneTable? {
        guard let url = Bundle.main.url(forResource: "SystemPanes", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SystemPaneTable(resource: data)
    }
}

// MARK: - Launch steps

extension AppEnvironment: LaunchSteps {
    func resolveLocation() async -> LaunchLocationDecision {
        #if DEBUG
        // Development builds run from DerivedData; the move offer is a shipped-app behaviour (PLT-R710).
        return .proceed
        #else
        let bundleURL = Bundle.main.bundleURL
        let launchGuard = self.launchGuard
        let files = FileManagerRelocationFiles()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let relocator = AppRelocator(
            files: files, relauncher: WorkspaceRelauncher(beforeLaunch: { launchGuard.markSurvived() }),
            applicationsDirectory: AppRelocator.applicationsDirectory(
                system: URL(fileURLWithPath: "/Applications", isDirectory: true),
                user: home.appendingPathComponent("Applications", isDirectory: true), files: files))
        let gate = LocationGate<AppLocationCheck.Reason>(
            verdict: { Self.locationVerdict(bundleURL) },
            offer: { [language, brand] reason in
                MoveOfferAlert.ask(reason: reason, appName: brand.displayName, language: language) == .move
            },
            reportFailure: { [weak self] _ in
                guard let self else { return }
                CompositionAlerts.moveFailed(appName: brand.displayName, strings: strings)
            }, relocator: relocator, bundleURL: bundleURL)
        return await gate.resolve()
        #endif
    }

    static func locationVerdict(_ bundleURL: URL) -> LocationGate<AppLocationCheck.Reason>.Verdict {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch AppLocationCheck.evaluate(bundleURL: bundleURL, homeDirectory: home, isOnReadOnlyVolume: readOnly) {
        case .ok: return .ok
        case .mustMove(let reason): return .mustMove(reason)
        }
    }

    func migrateLegacyStorage() {
        let brand = self.brand
        let bases = paths.bases
        utility.sync {
            _ = LegacyStorageMigrator.migrate(
                current: brand.storageFolderName, legacyNames: brand.legacyStorageFolderNames, bases: bases,
                fileSystem: LocalFileSystem())
        }
    }

    func loadSettings() async -> SettingsState {
        let state = await settingsStore.load()
        settings = state
        language.select(state.effective.interfaceLanguage)
        return state
    }

    func loadRules() -> RulesLoadResult {
        let url =
            Bundle.main.url(forResource: "compat-rules", withExtension: "json")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/compat-rules.json")
        return RulesLoader.load(contentsOf: url)
    }

    func startHost(rules: RulesLoadResult, settings: SettingsState) {
        host.start(rules: rules, settings: settings)
    }

    func showShell(settings: SettingsState, safeMode: Bool) {
        let item = StatusItemController(language: language, actions: self) { [unowned self] in menuModel() }
        statusItem = item
        switchHUD = SwitchHUDController(language: language)
        item.setClickToToggle(settings.effective.clickIconToToggle)
        updateIcon()
    }

    func presentOnboarding(settings: SettingsState) {
        presentOnboarding(startAt: nil)
    }

    func startUpdater(settings: SettingsState) {
        let host = self.host
        let controller = UpdaterController {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            return (secondsSinceLastKey: idle, secureInputOn: host.refreshSecureInput().enabled)
        }
        updater = controller
        applyUpdaterSettings()
        controller.start()
    }
}
