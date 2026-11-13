// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lifecycle owner of the input host (2.1). Main actor: it starts and stops threads, applies settings, drives
// the pure `HostLifecycle` state machine and performs its effects, and tells the shell what to show. It never
// sits on the per-keystroke path. Workstream W2-A (composition with the real services); the state machine
// itself is W1-F2. The effect, notice and settings paths live in `Integration/InputHostController+*.swift`.

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore
internal import VietnameseEngine

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
    /// ENG-R861 learning signal seen twice: added to the user list (open decision 8, visible and removable in
    /// Settings). The shell may mention it; it never logs the word.
    case learningProposal(LearningProposal)
}

public struct LearningProposal: Sendable, Hashable {
    public enum List: Sendable, Hashable { case keepAsTyped, keepVietnamese }
    public var list: List
    public var rawKeys: String  // content: shown to the user in Settings, never logged

    public init(list: List, rawKeys: String) {
        self.list = list
        self.rawKeys = rawKeys
    }
}

/// Why the session is inactive (PLT-R333); the host is active only when none applies.
enum SessionInactiveReason: Hashable {
    case asleep, screenLocked, sessionResigned
}

@MainActor
public final class InputHostController {
    let dependencies: InputHostDependencies
    let settingsStore: SettingsStore
    let hop: any MainThreadHop
    let channels: HostChannels
    let axThread: RunLoopThread
    let focusTracker: FocusTracker
    let worker: InjectionWorker
    let settingsPublisher: TapSettingsPublisher
    let tapLogDrainer: TapLogDrainer
    let makeTapThread: TapThreadMaker
    /// The clock the tap stamps events with; the worker, the tap watchdog and the log drainer share its base.
    let tapClock: any MonotonicClock
    /// False only in tests that drive the worker step by step (`InjectionWorker.runUntilIdle`).
    let runsWorkerThread: Bool
    let ruleBox = RuleSetBox()
    let refresh: RefreshRequests
    var inputSourceMonitor: InputSourceMonitor
    var permissionMonitor: PermissionMonitor?
    var secureInputMonitor: SecureInputMonitor?
    var workspaceToken: (any ObservationToken)?
    var drainTimer: (any ScheduledTimer)?
    var retryTimer: (any ScheduledTimer)?
    /// Bumped on every schedule and cancel; a fire whose hop to main carries an older value is stale.
    var retryGeneration: UInt64 = 0

    var lifecycle = HostLifecycle()
    var lifecycleGeneration: UInt64 = 0
    var pendingInputs: [LifecycleInput] = []
    var processingInputs = false
    var session: TapSession?
    /// A removed session whose thread may still be exiting; its echoes are retired before the next tap.
    var retiredSession: TapSession?
    var recorderActive = false
    var started = false
    var stopped = false

    var rules: RulesLoadResult?
    var ruleInputs: RuleSetInputs?
    var settings: SettingsState?
    var latestPermissions: PermissionStatus?
    var latestToggle: (sequence: UInt64, bundle: BundleKey?, mode: TypingMode)?
    var secureResumedGeneration: UInt64?
    var lastFocusKey: FocusKey?
    var captureGap: PauseCode?
    var conflicts: [ConflictingInput] = []
    var conflictsReported = false
    var conflictsRescanned = false
    var learning = LearningTracker()
    var inactiveReasons: Set<SessionInactiveReason> = []

    public internal(set) var state: HostState = .starting

    public var onEvent: (@MainActor (HostEvent) -> Void)?

    /// Production wiring: the real tap thread and pipeline, the main dispatch queue for hops, the uptime clock
    /// for everything that shares a base with the tap's event timestamps.
    public convenience init(dependencies: InputHostDependencies, settingsStore: SettingsStore) {
        self.init(
            dependencies: dependencies, settingsStore: settingsStore, hop: DispatchMainHop(),
            makeTapThread: TapSession.productionThreadMaker(factory: dependencies.tapFactory), tapClock: MachClock(),
            loadBundled: TapSettingsPublisher.bundledLoader, macOSVersion: Self.macOSVersion,
            runsWorkerThread: true)
    }

    init(
        dependencies: InputHostDependencies, settingsStore: SettingsStore, hop: any MainThreadHop,
        makeTapThread: @escaping TapThreadMaker, tapClock: any MonotonicClock,
        loadBundled: @escaping TapSettingsPublisher.BundledResourcesLoader, macOSVersion: LooseVersion,
        runsWorkerThread: Bool
    ) {
        self.runsWorkerThread = runsWorkerThread
        self.dependencies = dependencies
        self.settingsStore = settingsStore
        self.hop = hop
        self.makeTapThread = makeTapThread
        self.tapClock = tapClock
        refresh = RefreshRequests(hop: hop)
        let initial = InitialSnapshots.make(
            source: dependencies.inputSources.currentSource(), settings: Self.placeholderSettings,
            globalMode: .vietnamese)
        channels = HostChannels(initial: initial, marker: .random(), signalQueue: dependencies.utilityQueue)
        axThread = RunLoopThread(name: "ax", qualityOfService: .userInitiated)
        let refresh = self.refresh
        focusTracker = FocusTracker(
            thread: axThread,
            ax: FocusChangeSignalingAXProvider(base: dependencies.ax, thread: axThread) { refresh.request() },
            processes: dependencies.processes, output: channels.snapshots.focus,
            generation: channels.focusGeneration, inbox: channels.outbox.toAX, metrics: dependencies.metrics,
            health: dependencies.health, clock: dependencies.clock, macOSVersion: macOSVersion)
        worker = InjectionWorker(
            queue: channels.queue, signal: channels.workerSignal, feedback: channels.feedback,
            marker: channels.marker, focusGeneration: channels.focusGeneration,
            services: InjectionServices(
                poster: dependencies.poster, fieldAccess: dependencies.fieldAccess, pasteboard: dependencies.pasteboard,
                clock: tapClock, metrics: dependencies.metrics, health: dependencies.health,
                logger: dependencies.logger, capture: dependencies.capture))
        settingsPublisher = TapSettingsPublisher(
            cell: channels.snapshots.settings, logger: dependencies.logger, loadBundled: loadBundled)
        tapLogDrainer = TapLogDrainer(
            ring: dependencies.tapLog, health: dependencies.health, logger: dependencies.logger, clock: tapClock,
            wallClock: dependencies.wallClock)
        let inputSourceCell = channels.snapshots.inputSource
        inputSourceMonitor = InputSourceMonitor(
            provider: dependencies.inputSources, builder: dependencies.layoutBuilder
        ) { snapshot in
            inputSourceCell.publish(snapshot)
            refresh.request()
        }
        refresh.connect { [weak self] in self?.refreshState() }
        makeMonitors()
        connectSignals()
    }

    /// Ready after launch within 300 ms target / 1 s gate when permissions are granted (S1). The first settings
    /// snapshot (engine catalog with the bundled lists, ENG-R1231) is built on the utility queue before the
    /// lifecycle may create the tap, so the first key already has the real engines.
    public func start(rules: RulesLoadResult, settings: SettingsState) {
        guard !started, !stopped else { return }
        started = true
        self.rules = rules
        self.settings = settings
        let publisher = settingsPublisher
        dependencies.utilityQueue.sync {
            publisher.preloadResources()
            publisher.publish(settings)
        }
        startServices(rules: rules, settings: settings)
        feed(.launched)
        detectConflicts()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        stopServices()
    }

    /// Rebuilds engines and snapshots (utility queue) and re-resolves focus (ax) (PLT-R1008, PRD-R27).
    /// Before `start` it only records the state; `start` publishes it.
    public func apply(settings: SettingsState) {
        guard !stopped else { return }
        self.settings = settings
        guard started else { return }
        applySettings(settings)
    }

    /// Menu radio or click-to-toggle (D16). Hard boundary; updates per-app memory (PRD-R20).
    public func setMode(_ mode: TypingMode, manual: Bool) {
        focusTracker.setMode(mode)
        refreshAfterAXWork()
        onEvent?(.modeChanged(mode, manual: manual, bundle: currentFocus().app?.bundle))
    }

    /// Status for the menu "Với <App>" submenu and diagnostics.
    public func currentFocus() -> FocusSnapshot { channels.snapshots.focus.load() }

    /// Immediate secure-input poll when the menu opens (PLT-R395).
    public func refreshSecureInput() -> SecureInputSnapshot {
        secureInputMonitor?.pollNow() ?? channels.snapshots.secureInput.load()
    }

    /// Immediate permission check on menu open, wake and session activation (PLT-R721).
    public func refreshPermissions() -> PermissionStatus {
        guard let monitor = permissionMonitor else { return latestPermissions ?? Self.unknownPermissions }
        let status = monitor.checkNow()
        latestPermissions = status
        return status
    }

    /// Onboarding's permission screen is visible: poll every second for at most 5 minutes (PLT-R711).
    public func setPermissionFastPolling(_ enabled: Bool) {
        permissionMonitor?.setFastPolling(enabled)
    }

    /// The settings window's recorder is capturing keys: suspend hotkeys (PRD-R15).
    public func setRecorderActive(_ active: Bool) {
        guard active != recorderActive else { return }
        recorderActive = active
        publishLifecycle(lifecycle.phase)
    }

    /// Data for the diagnostics report (PLT-R1202), metadata only.
    public func reportContext() -> HostReportContext {
        HostReportContext(
            state: state, focus: currentFocus(), decision: focusTracker.currentDecision(),
            inputSource: channels.snapshots.inputSource.load(),
            enabledSources: dependencies.inputSources.enabledSources(),
            secureInput: channels.snapshots.secureInput.load(),
            permissions: latestPermissions ?? Self.unknownPermissions, tapEnabled: session?.thread.isEnabled ?? false,
            conflicts: conflicts)
    }
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
