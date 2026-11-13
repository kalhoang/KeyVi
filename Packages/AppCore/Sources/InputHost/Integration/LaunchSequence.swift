// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The launch order of the app (contracts.md section 12 "AppShell", PLT-R710, PLT-R1009, ADR 0307, S1). The
// composition root implements the steps with the real services; the order and the branches live here so they
// are tested with fakes. Workstream W2-A.

public import AppModel
public import CompatRules
public import RealtimeSupport
public import SettingsStore

/// What the location step decided (PLT-R710).
public enum LaunchLocationDecision: Sendable, Hashable {
    /// The app runs from /Applications or ~/Applications and is not translocated (or the check passed).
    case proceed
    /// The app moved itself and launched the copy; this process must quit without doing anything else.
    case relocating
    /// The user declined the move, or the move failed: quit without requesting any permission.
    case quit
}

/// The steps the composition root performs, in the order `LaunchSequence` calls them.
@MainActor
public protocol LaunchSteps: AnyObject {
    /// PLT-R710, before anything that could request a permission.
    func resolveLocation() async -> LaunchLocationDecision
    /// ADR 0307: a renamed product's old folders move to the current name before the settings are read.
    func migrateLegacyStorage()
    /// PLT-R1002-R1009 (honours safe mode through the launch guard).
    func loadSettings() async -> SettingsState
    /// PLT-R503: never fails; falls back to the embedded rules.
    func loadRules() -> RulesLoadResult
    func startHost(rules: RulesLoadResult, settings: SettingsState)
    /// Status item and menu (PRD-R9); in safe mode with the reset and exit actions reachable (PLT-R1009).
    func showShell(settings: SettingsState, safeMode: Bool)
    /// PRD-R40: first launch, or a launch before onboarding was completed.
    func presentOnboarding(settings: SettingsState)
    func startUpdater(settings: SettingsState)
}

/// Runs the launch once and owns the "launch survived" timer of the crash-loop guard.
@MainActor
public final class LaunchSequence {
    public enum Outcome: Sendable, Hashable {
        case running(safeMode: Bool)
        case relocating
        case quit
    }

    /// The step reached so far, for diagnostics and tests.
    public enum Stage: Int, Sendable, Hashable, Comparable {
        case notStarted, guardChecked, locationResolved, storageMigrated, settingsLoaded, rulesLoaded, hostStarted,
            shellShown, onboardingDecided, updaterStarted

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let launchGuard: LaunchGuard
    private let appVersion: String
    private let wallClock: any WallClock
    private let scheduler: any TimerScheduler
    private let steps: any LaunchSteps
    private var survivalTimer: (any ScheduledTimer)?
    public private(set) var stage = Stage.notStarted

    /// `appVersion` is `CFBundleShortVersionString` plus the build, so installing an update clears a crash loop
    /// (W1-B request; `LaunchGuard.beginLaunch(now:appVersion:)`).
    public init(
        launchGuard: LaunchGuard, appVersion: String, wallClock: any WallClock, scheduler: any TimerScheduler,
        steps: any LaunchSteps
    ) {
        self.launchGuard = launchGuard
        self.appVersion = appVersion
        self.wallClock = wallClock
        self.scheduler = scheduler
        self.steps = steps
    }

    /// The "bundle version" the guard compares: `1.2.0 (45)`.
    public static func versionString(short: String, build: String) -> String { "\(short) (\(build))" }

    public func run() async -> Outcome {
        guard stage == .notStarted else { return .running(safeMode: launchGuard.isSafeModeActive) }
        let safeMode = launchGuard.beginLaunch(now: wallClock.now().timeIntervalSince1970, appVersion: appVersion)
        stage = .guardChecked
        switch await steps.resolveLocation() {
        case .proceed: stage = .locationResolved
        case .relocating:
            launchGuard.markSurvived()  // a deliberate quit is not a crash
            return .relocating
        case .quit:
            launchGuard.markSurvived()
            return .quit
        }
        steps.migrateLegacyStorage()
        stage = .storageMigrated
        let settings = await steps.loadSettings()
        stage = .settingsLoaded
        let rules = steps.loadRules()
        stage = .rulesLoaded
        steps.startHost(rules: rules, settings: settings)
        stage = .hostStarted
        steps.showShell(settings: settings, safeMode: safeMode)
        stage = .shellShown
        // PLT-R1009: safe mode reads no files, so it must not run onboarding over the user's real settings.
        if !safeMode && settings.user.onboarding.completedVersion == nil { steps.presentOnboarding(settings: settings) }
        stage = .onboardingDecided
        steps.startUpdater(settings: settings)
        stage = .updaterStarted
        armSurvivalTimer()
        return .running(safeMode: safeMode)
    }

    /// Clean quit: the launch counts as survived (PLT-R1009).
    public func terminate() {
        survivalTimer?.cancel()
        survivalTimer = nil
        launchGuard.markSurvived()
    }

    private func armSurvivalTimer() {
        let launchGuard = self.launchGuard
        let delay = TimeSpan.seconds(LaunchGuard.survivalSeconds)
        survivalTimer = scheduler.schedule(after: delay, leeway: delay / 10) { launchGuard.markSurvived() }
    }
}
