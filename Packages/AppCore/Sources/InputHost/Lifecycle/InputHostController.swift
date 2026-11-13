// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lifecycle owner of the input host (2.1). Main actor: it starts and stops threads, applies settings, drives
// the pure `HostLifecycle` state machine and performs its effects, and tells the shell what to show. It never
// sits on the per-keystroke path. Workstream W2-A (composition with the real services); the state machine
// itself is W1-F2.

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore

/// Everything the host needs from the platform, injected so the whole host runs under fakes in tests.
public struct InputHostDependencies: Sendable {
    public var tapFactory: any EventTapFactory
    public var poster: any EventPoster
    public var fieldAccess: any FocusedFieldAccess
    public var pasteboard: any PasteboardAccess
    public var ax: any AXProvider
    public var processes: any ProcessIdentityProvider
    public var bundleInspector: any BundleInspector
    public var inputSources: any InputSourceProvider
    public var layoutBuilder: any LayoutTableBuilding
    public var secureInput: any SecureInputProbe
    public var permissions: any PermissionProbe
    public var workspace: any WorkspaceEvents
    public var keyValueStore: any KeyValueStore
    /// Services' clock (ADR 0313). The tap pipeline itself is `KeyPipeline<_, MachClock>` in production.
    public var clock: any MonotonicClock
    /// Timers of the monitors, the tap watchdog and the lifecycle backoff (production:
    /// `DispatchTimerScheduler(queue: utilityQueue)`; tests: `ManualScheduler`).
    public var scheduler: any TimerScheduler
    public var wallClock: any WallClock
    public var metrics: PlatformMetrics
    public var health: HealthEventLog
    public var logger: any DiagnosticsLogging
    public var tapLog: TapLogRing
    public var capture: CaptureController?
    /// Serial utility queue shared with SettingsStore and Diagnostics (PLT-R203).
    public var utilityQueue: DispatchSerialQueue

    public init(
        tapFactory: any EventTapFactory, poster: any EventPoster, fieldAccess: any FocusedFieldAccess,
        pasteboard: any PasteboardAccess, ax: any AXProvider, processes: any ProcessIdentityProvider,
        bundleInspector: any BundleInspector, inputSources: any InputSourceProvider,
        layoutBuilder: any LayoutTableBuilding, secureInput: any SecureInputProbe, permissions: any PermissionProbe,
        workspace: any WorkspaceEvents, keyValueStore: any KeyValueStore, clock: any MonotonicClock,
        scheduler: any TimerScheduler, wallClock: any WallClock,
        metrics: PlatformMetrics, health: HealthEventLog, logger: any DiagnosticsLogging, tapLog: TapLogRing,
        capture: CaptureController?, utilityQueue: DispatchSerialQueue
    ) {
        self.tapFactory = tapFactory
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
        self.ax = ax
        self.processes = processes
        self.bundleInspector = bundleInspector
        self.inputSources = inputSources
        self.layoutBuilder = layoutBuilder
        self.secureInput = secureInput
        self.permissions = permissions
        self.workspace = workspace
        self.keyValueStore = keyValueStore
        self.clock = clock
        self.scheduler = scheduler
        self.wallClock = wallClock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.tapLog = tapLog
        self.capture = capture
        self.utilityQueue = utilityQueue
    }
}

/// What the shell reacts to (icon, HUD, status line, notices).
public enum HostEvent: Sendable {
    case stateChanged(HostState)
    /// `manual` = toggle hotkey or menu; the HUD shows only for manual switches (D14, PRD-R12).
    case modeChanged(TypingMode, manual: Bool, bundle: BundleKey?)
    case focusChanged(bundle: BundleKey?, rule: RuleID?)
    /// More than 3 tap disables within 10 minutes (PLT-R330 step 5), or one not recovered within 1 s (PRD-R43).
    case tapInstabilityNotice
    case conflictsDetected([ConflictingInput])
    case permissionsChanged(PermissionStatus)
    /// ENG-R861 learning signal seen twice: proposed for the user list (open decision 8).
    case learningProposal(LearningProposal)
}

public struct LearningProposal: Sendable, Hashable {
    public enum List: Sendable, Hashable { case keepAsTyped, keepVietnamese }
    public var list: List
    public var rawKeys: String  // content: shown to the user in Settings, never logged
}

@MainActor
public final class InputHostController {
    public init(dependencies: InputHostDependencies, settingsStore: SettingsStore) { unimplemented() }

    public private(set) var state: HostState {
        get { unimplemented() }
        set { unimplemented() }
    }

    public var onEvent: (@MainActor (HostEvent) -> Void)? {
        get { unimplemented() }
        set { unimplemented() }
    }

    /// Ready after launch within 300 ms target / 1 s gate when permissions are granted (S1).
    public func start(rules: RulesLoadResult, settings: SettingsState) { unimplemented() }
    public func stop() { unimplemented() }

    /// Rebuilds engines and snapshots (utility queue) and re-resolves focus (ax) (PLT-R1008, PRD-R27).
    public func apply(settings: SettingsState) { unimplemented() }

    /// Menu radio or click-to-toggle (D16). Hard boundary; updates per-app memory (PRD-R20).
    public func setMode(_ mode: TypingMode, manual: Bool) { unimplemented() }

    /// Status for the menu "Với <App>" submenu and diagnostics.
    public func currentFocus() -> FocusSnapshot { unimplemented() }

    /// Immediate secure-input poll when the menu opens (PLT-R395).
    public func refreshSecureInput() -> SecureInputSnapshot { unimplemented() }

    /// Immediate permission check on menu open, wake and session activation (PLT-R721).
    public func refreshPermissions() -> PermissionStatus { unimplemented() }

    /// The settings window's recorder is capturing keys: suspend hotkeys (PRD-R15).
    public func setRecorderActive(_ active: Bool) { unimplemented() }

    /// Data for the diagnostics report (PLT-R1202), metadata only.
    public func reportContext() -> HostReportContext { unimplemented() }
}

/// Host-side inputs of `DiagnosticsReport` (assembled by ShellCore).
public struct HostReportContext: Sendable {
    public var state: HostState
    public var focus: FocusSnapshot
    public var decision: ResolvedDecision?
    public var inputSource: InputSourceSnapshot
    public var enabledSources: [InputSourceInfo]
    public var secureInput: SecureInputSnapshot
    public var permissions: PermissionStatus
    public var tapEnabled: Bool
    public var conflicts: [ConflictingInput]
}
