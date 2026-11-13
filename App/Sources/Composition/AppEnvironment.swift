// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composition root (workstream W2-A). Builds every production service once, wires AppCore modules together
// and owns the window controllers. Main actor only. The launch order is `LaunchSequence` (InputHost
// Integration, tested with fakes); the shell and onboarding wiring live in `AppEnvironment+*.swift`.

import AppKit
import AppModel
import Carbon.HIToolbox
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
    let utility: DispatchQueue
    let keyValues = UserDefaultsKeyValueStore()
    let launchGuard: LaunchGuard
    let diagnostics: DiagnosticsWiring
    let loginItem = SMAppServiceLoginItem(openLegacyLoginItems: AppEnvironment.openLegacyLoginItems)
    let settingsChanges = MainActorRelay<SettingsState>()
    /// System uptime at launch: keys pressed before it do not count for the relaunch policy (PLT-R1105).
    let launchUptime = ProcessInfo.processInfo.systemUptime
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
    /// The latest latency probe result (PLT-R810), included in the next diagnostics report.
    var latencyProbeResult: LatencyProbeResult?
    lazy var paneTable: SystemPaneTable? = Self.loadPaneTable()
    /// The bundled compatibility matrix, read the first time the menu opens (PRD-R43 known-limitation line).
    lazy var matrix: MatrixDocument? = SettingsResources.bundledMatrix()
    #if INTEGRATION_HOOKS
    /// The self-hosted runner's test build only: answers the integration hooks (ADR 0502).
    let integrationHooks: IntegrationHooksApp
    #endif
    /// QA-R42: the first launch after an update checks the host once it left `starting`.
    var selfCheckPending = false
    /// PRD-R43: the "tap re-enabled" line stays in the status menu for a while after an instability notice.
    var tapReenabledUntil: Date?
    var lastMenuRefresh: Date?
    /// The quit under way (AppEnvironment+Quit.swift): settings flushed off the main actor, reply through the run loop.
    var quit: QuitCoordinator?

    /// Launch order (S1 target 300 ms to tap active): LaunchGuard -> AppLocationCheck (move offer before any
    /// permission request, PLT-R710) -> LegacyStorageMigrator -> SettingsStore.load ->
    /// RulesLoader.load(compat-rules.json) -> InputHostController.start -> StatusItemController -> onboarding if
    /// not completed (PRD-R40, PRD-R42) -> UpdaterController.start.
    init(bundle: Bundle) {
        brand = Brand.from(bundle)
        language = InterfaceLanguageModel(language: DefaultSettings.v1.interfaceLanguage, appBundle: bundle)
        paths = StoragePaths(folder: brand.storageFolderName)
        utility = DispatchQueue(label: brand.slug + ".utility", qos: .utility)
        launchGuard = LaunchGuard(store: keyValues)
        diagnostics = DiagnosticsWiring(
            paths: paths, subsystem: brand.bundleIdentifier, utility: utility, defaults: .standard)
        let relay = settingsChanges
        settingsStore = SettingsStore(
            location: StorageLocation(directory: paths.applicationSupport), fileSystem: LocalFileSystem(),
            wallClock: SystemWallClock(), writtenBy: brand.version, queue: utility, launchGuard: launchGuard,
            onChange: { relay.send($0) })
        var hostDependencies = InputHostDependencies.production(
            diagnostics: diagnostics, keyValues: keyValues, utility: utility)
        #if INTEGRATION_HOOKS
        integrationHooks = IntegrationHooksApp(instrumenting: &hostDependencies)
        #endif
        host = InputHostController(dependencies: hostDependencies, settingsStore: settingsStore)
        settingsChanges.connect { [weak self] state in self?.settingsChanged(state) }
        host.onEvent = { [weak self] event in self?.hostEvent(event) }
    }

    func start() {
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
        diagnostics.startMaintenance()
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
        reportNewNotices(state.notices)
        settings = state
        safeMode = state.safeMode  // PLT-R1009: the store decides; leaving safe mode reloads the files
        host.apply(settings: state)
        language.select(state.effective.interfaceLanguage)
        statusItem?.setClickToToggle(state.effective.clickIconToToggle)
        settingsWindow?.settingsChanged(state)  // changes made elsewhere show at once (menu, memory, import)
        applyUpdaterSettings()
        updateIcon()
    }

    /// PLT-R1006, PLT-R1007, PLT-R1202: each new store notice is logged (contracts.md `LogEvent.SettingsEvent`)
    /// and recorded as a health event, so the log and the report show the episode even if Settings never opens.
    /// Compared with `settings.notices`, which still holds the previous state.
    func reportNewNotices(_ notices: [StoreNotice]) {
        let now = Date()
        for notice in StoreNoticeReporting.added(previous: settings.notices, current: notices) {
            if let event = StoreNoticeReporting.logEvent(notice) {
                diagnostics.logger.log(.settings(event), level: StoreNoticeReporting.logLevel(notice))
            }
            if let health = StoreNoticeReporting.healthEvent(notice, at: now) { diagnostics.health.record(health) }
        }
    }

    /// D19-D21 from the store reach Sparkle through `apply`, which never reports back (setting the controller's
    /// properties would record the stored values as new user choices, PRD-R6).
    func applyUpdaterSettings() {
        updater?.apply(UpdatePreferences(settings.effective))
    }

    /// PLT-R1105: seconds since the last key press since launch (`.infinity` when none) and the system's secure
    /// input state. Read once, when Sparkle offers the immediate install.
    func keyboardIdleState() -> (secondsSinceLastKey: Double, secureInputOn: Bool) {
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let idle = KeyboardIdleReading.secondsSinceLastKey(
            systemIdleSeconds: systemIdle, secondsSinceLaunch: ProcessInfo.processInfo.systemUptime - launchUptime)
        return (secondsSinceLastKey: idle, secureInputOn: IsSecureEventInputEnabled())
    }

    /// macOS 12 (ADR 0315): no `SMAppService`, so the System Preferences button opens System Preferences >
    /// Users & Groups, where the user adds the app to Login Items by hand.
    nonisolated private static func openLegacyLoginItems() {
        guard let url = loadPaneTable()?.deepLink(.loginItems, macOS: InputHostController.macOSVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated private static func loadPaneTable() -> SystemPaneTable? {
        guard let url = Bundle.main.url(forResource: "SystemPanes", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SystemPaneTable(resource: data)
    }
}

// MARK: - Launch steps

extension AppEnvironment: LaunchSteps {
    func resolveLocation() async -> LaunchLocationDecision {
        #if DEBUG || INTEGRATION_HOOKS
        // Development builds run from DerivedData; the move offer is a shipped-app behaviour (PLT-R710). The
        // runner's test build is installed at one fixed path whose TCC grants a move would lose, and it never
        // shows a modal offer (scripts/run-integration.sh build).
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
                CompositionAlerts.moveFailed(appName: brand.displayName, localizer: language.localizer)
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
        reportNewNotices(state.notices)
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
        #if INTEGRATION_HOOKS
        startIntegrationHooks()
        #endif
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

    /// PLT-R1101: D19-D21 are applied before Sparkle starts; changes the user makes in the updater (About & Support,
    /// Sparkle's window) are written to settings.json as explicit keys, one key per change (PRD-R6).
    func startUpdater(settings: SettingsState) {
        let controller = UpdaterController(
            idleState: { [weak self] in self?.keyboardIdleState() ?? (secondsSinceLastKey: 0, secureInputOn: true) },
            dependencies: .live(bundle: .main, logger: diagnostics.logger, language: language))
        let store = settingsStore
        controller.onPreferenceChange = { change in
            Task { await store.updateSettings { change.apply(to: &$0) } }
        }
        updater = controller
        controller.apply(UpdatePreferences(settings.effective))
        controller.start()
    }
}
