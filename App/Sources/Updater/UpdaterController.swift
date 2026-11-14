// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrapper around Sparkle 2 (PLT-R1101-R1110, PRD-R50-R55, docs/decisions/0304-sparkle-version-pin.md).
// Workstream W2-D.
//
// Settings D19-D21 live in settings.json (PLT-R1001); this controller mirrors them into Sparkle at launch and on
// every change, and reports user changes made here (About pane, Sparkle's update window) back through
// `onPreferenceChange` so the composition root writes them to the settings store. Sparkle starts only when the
// bundle carries an https feed on the site host and a valid EdDSA key (PLT-R1102).

import AppKit
import AppModel
import Diagnostics
import ShellCore
import Sparkle

/// What the controller needs from the outside. `live` is the production wiring; tests pass fakes.
@MainActor
struct UpdaterDependencies {
    /// The app's Info.plist: brand keys, and the Sparkle keys checked before start.
    var info: [String: Any]
    /// Runs work on a later turn of the main queue, after blocks already queued there (production:
    /// `DispatchQueue.main.async`). Sparkle ends a failed session on such a turn once it is acknowledged.
    var onNextMainTurn: @MainActor (_ work: @escaping @MainActor () -> Void) -> Void
    var logger: (any DiagnosticsLogging)?
    /// The interface language of the moment (D18): the update-failed alert follows it, not the macOS language.
    var localizer: @MainActor () -> Localizer
    var presenter: any UpdateFailurePresenting
    var openURL: @MainActor (URL) -> Void
    var makeDriver: UpdateDriverFactory

    static func live(
        bundle: Bundle = .main, logger: (any DiagnosticsLogging)? = nil, language: InterfaceLanguageModel? = nil
    ) -> UpdaterDependencies {
        let fallback = Localizer(language: .vietnamese, appBundle: bundle)
        return UpdaterDependencies(
            info: bundle.infoDictionary ?? [:], onNextMainTurn: Self.mainQueueAsync, logger: logger,
            localizer: { language?.localizer ?? fallback }, presenter: AlertUpdateFailurePresenter(),
            openURL: { _ = NSWorkspace.shared.open($0) }, makeDriver: SparkleDriver.factory(bundle: bundle))
    }

    private static func mainQueueAsync(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

@MainActor
final class UpdaterController: NSObject, UpdaterControlling {
    /// User changes of D19-D21 made through this controller; the composition root persists them with
    /// `change.apply(to:)` inside `SettingsStore.updateSettings` (PRD-R6: only the changed key becomes explicit).
    var onPreferenceChange: (@MainActor (UpdatePreferenceChange) -> Void)?

    private let dependencies: UpdaterDependencies
    private let brand: Brand
    private let idleState: @MainActor () -> KeyboardIdleState
    private var preferences = UpdatePreferences.shipped
    /// What Sparkle reported right after the last push. A later read-back that differs is a choice the user made
    /// in Sparkle's own window; one that never moved (a setter Sparkle ignored) is not (PRD-R6).
    private var sparkleBaseline: SparkleChoices?
    private var driver: (any UpdateDriving)?
    private var startAttempted = false

    /// `idleState` answers "seconds since the last key press, and is secure input on?" for the relaunch policy
    /// (PLT-R1105). Use `.infinity` seconds when no key was pressed since launch.
    init(
        idleState: @escaping @MainActor () -> (secondsSinceLastKey: Double, secureInputOn: Bool),
        dependencies: UpdaterDependencies = .live()
    ) {
        self.dependencies = dependencies
        brand = Brand.from(info: dependencies.info)
        self.idleState = {
            let state = idleState()
            return KeyboardIdleState(secondsSinceLastKey: state.secondsSinceLastKey, secureInputOn: state.secureInputOn)
        }
        super.init()
    }

    /// Starts Sparkle once, as the last step of the launch order. Without a valid configuration nothing starts, the
    /// refusal is logged and "Check for updates" stays disabled (PLT-R1102).
    func start() {
        guard !startAttempted else { return }
        startAttempted = true
        if let refusal = UpdaterConfiguration.refusal(info: dependencies.info) {
            log(.failed(code: refusal.rawValue), level: .error)
            return
        }
        let driver = dependencies.makeDriver(self) { [weak self] error, acknowledgement in
            guard let self else { return acknowledgement() }
            presentFailure(error, acknowledgement: acknowledgement)
        }
        driver.sendsSystemProfile = false  // PRD-R55, also off in Info.plist and filtered by the delegate.
        push(preferences, to: driver)
        do {
            try driver.start()
            self.driver = driver
        } catch {
            log(.failed(code: (error as NSError).code), level: .error)
        }
    }

    /// Applies D19-D21 from the settings store, at launch (before `start`) and after every settings change.
    /// Idempotent, and the stored values are never reported back through `onPreferenceChange`. A value the user
    /// moved in Sparkle's own update window since the last push is adopted first (reported once, so the store
    /// keeps it) rather than overwritten by the store's older value: the store publishes on every change, also
    /// while Sparkle's window is open (PLT-R1001, PRD-R6).
    func apply(_ next: UpdatePreferences) {
        let moves = sparkleMoves().filter { next.applying($0) != next }
        commit(moves.reduce(next) { $0.applying($1) })
        for change in moves { onPreferenceChange?(change) }
    }

    var currentPreferences: UpdatePreferences { preferences }

    // MARK: UpdaterControlling

    var canCheckForUpdates: Bool { driver?.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { preferences.automaticallyCheck }
        set { userChanged(.automaticallyCheck(newValue)) }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { preferences.automaticallyInstall }
        set { userChanged(.automaticallyInstall(newValue)) }
    }

    var channel: UpdateChannelSelection {
        get { UpdateChannelPolicy.selection(for: preferences.channel) }
        set { userChanged(.channel(UpdateChannelPolicy.channel(for: newValue))) }
    }

    func checkForUpdates() {
        guard let driver, driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    // MARK: Internals

    private func userChanged(_ change: UpdatePreferenceChange) {
        let next = preferences.applying(change)
        guard next != preferences else { return }
        commit(next)
        onPreferenceChange?(change)
    }

    private func commit(_ next: UpdatePreferences) {
        let previous = preferences
        preferences = next
        guard let driver else { return }
        push(next, to: driver)
        // Sparkle's documented call after a channel change, so the new channel is used without waiting a day.
        if previous.channel != next.channel { driver.resetUpdateCycleAfterShortDelay() }
    }

    /// Writes only values that differ: setting `automaticallyChecksForUpdates` makes Sparkle reschedule its cycle.
    private func push(_ preferences: UpdatePreferences, to driver: any UpdateDriving) {
        if driver.automaticallyChecksForUpdates != preferences.automaticallyCheck {
            driver.automaticallyChecksForUpdates = preferences.automaticallyCheck
        }
        if driver.automaticallyDownloadsUpdates != preferences.automaticallyInstall {
            driver.automaticallyDownloadsUpdates = preferences.automaticallyInstall
        }
        sparkleBaseline = SparkleChoices(of: driver)
    }

    /// Sparkle's update window has an "automatically download and install" checkbox that writes Sparkle's own
    /// defaults. Adopting it at the end of a session keeps settings.json the single source (PLT-R1001). Only a
    /// value that moved since the last push counts: Sparkle silently ignores `automaticallyDownloadsUpdates` when
    /// the bundle disallows automatic updates, and that must never turn into an explicit D20 (PRD-R6).
    private func adoptSparkleChoices() { apply(preferences) }

    /// The Sparkle values that moved since the last push, as preference changes.
    private func sparkleMoves() -> [UpdatePreferenceChange] {
        guard let driver, let baseline = sparkleBaseline else { return [] }
        let current = SparkleChoices(of: driver)
        var moves: [UpdatePreferenceChange] = []
        if current.automaticallyCheck != baseline.automaticallyCheck {
            moves.append(.automaticallyCheck(current.automaticallyCheck))
        }
        if current.automaticallyDownload != baseline.automaticallyDownload {
            moves.append(.automaticallyInstall(current.automaticallyDownload))
        }
        return moves
    }

    /// PRD-R43 update-failed alert. The failure itself is logged by `updater(_:didAbortWithError:)`.
    ///
    /// Sparkle closes its "Checking for updates" and progress windows only when the session ends, which happens on
    /// the main-queue turn after the acknowledgement. So the session is acknowledged first and the alert is shown
    /// on a later turn: it never sits on top of a frozen progress window, and "Thử lại" can start a new check.
    private func presentFailure(_ error: NSError, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        dependencies.onNextMainTurn { [weak self] in self?.showFailureAlert() }
    }

    private func showFailureAlert() {
        let content = UpdateFailureContent(
            localizer: dependencies.localizer(), appName: brand.displayName, version: brand.version,
            siteHost: brand.siteHost)
        switch dependencies.presenter.present(content) {
        case .retry:
            checkForUpdates()
        case .download:
            dependencies.openURL(content.downloadURL)
        case .close:
            break
        }
    }

    private func log(_ event: LogEvent.UpdateEvent, level: LogLevel) {
        dependencies.logger?.log(.update(event), level: level)
    }
}

/// The two Sparkle settings the user can flip in Sparkle's own windows.
private struct SparkleChoices: Equatable {
    var automaticallyCheck: Bool
    var automaticallyDownload: Bool

    @MainActor
    init(of driver: any UpdateDriving) {
        automaticallyCheck = driver.automaticallyChecksForUpdates
        automaticallyDownload = driver.automaticallyDownloadsUpdates
    }
}

/// `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR` in Sparkle 2.10.1, so its requirements are main-actor isolated and
/// these witnesses are checked by the compiler. The ADR 0313 pattern (`nonisolated` plus `MainActor.assumeIsolated`)
/// is not used: under Swift 6 region isolation it cannot store Sparkle's non-Sendable install block in main-actor
/// state.
extension UpdaterController: SPUUpdaterDelegate {
    /// `["beta"]` only after the user opted in (PLT-R1101, PRD-R53).
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannelPolicy.allowedChannels(for: preferences.channel)
    }

    /// Install on quit by default (PLT-R1105). The handler is taken, and run at once, only when the keyboard has
    /// been idle for 60 s with secure input off and the update is not critical. Otherwise this returns false:
    /// returning true stalls Sparkle's update cycle until the handler runs, which would disable "Check for
    /// updates", stop the 24 h schedule and hide critical updates (PRD-R54) while the keyboard stays busy.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        switch RelaunchGate.decision(for: idleState(), isCritical: item.isCriticalUpdate) {
        case .installNow:
            log(.installingNow, level: .info)
            immediateInstallHandler()
            return true
        case .installOnQuit:
            log(.installScheduledOnQuit, level: .info)
            return false
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        log(.checkStarted(manual: updateCheck == .updates), level: .info)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log(.updateFound(build: item.versionString), level: .notice)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let code = (error as NSError).code
        guard UpdateFailureFilter.isFailure(code: code) else { return }
        log(.failed(code: code), level: .error)
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        adoptSparkleChoices()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        adoptSparkleChoices()
    }

    /// PRD-R55: no system profile, even if a future Info.plist turned profiling on.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    /// PLT-R906: the appcast request carries no extra parameters.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }
}
