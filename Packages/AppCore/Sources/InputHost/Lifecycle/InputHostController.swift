// SPDX-License-Identifier: GPL-3.0-or-later
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
    public var utilityQueue: DispatchQueue
    /// PLT-R802 intervals for the tap callback, injection jobs and AX calls. When nil, the production
    /// controller creates them with the bundle identifier as subsystem.
    public var signposts: PlatformSignposts?

    public init(
        tapFactory: any EventTapFactory, poster: any EventPoster, fieldAccess: any FocusedFieldAccess,
        pasteboard: any PasteboardAccess, ax: any AXProvider, processes: any ProcessIdentityProvider,
        bundleInspector: any BundleInspector, inputSources: any InputSourceProvider,
        layoutBuilder: any LayoutTableBuilding, secureInput: any SecureInputProbe, permissions: any PermissionProbe,
        workspace: any WorkspaceEvents, keyValueStore: any KeyValueStore, clock: any MonotonicClock,
        scheduler: any TimerScheduler, wallClock: any WallClock,
        metrics: PlatformMetrics, health: HealthEventLog, logger: any DiagnosticsLogging, tapLog: TapLogRing,
        capture: CaptureController?, utilityQueue: DispatchQueue, signposts: PlatformSignposts? = nil
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
        self.signposts = signposts
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
    /// ENG-R861 learning signal seen twice in the same app: added to that app's learned words (ENG-R862, visible,
    /// removable and promotable to global in Settings). The shell may mention it; it never logs the word.
    case learningProposal(LearningProposal)
}

/// ENG-R862: a learning signal seen twice in one app, stored for that app only.
public struct LearningProposal: Sendable, Hashable {
    public typealias List = RestoreList
    public var list: List
    public var rawKeys: String  // content: shown to the user in Settings, never logged
    /// The app the signals came from; the learned word applies only there.
    public var app: BundleKey

    public init(list: List, rawKeys: String, app: BundleKey) {
        self.list = list
        self.rawKeys = rawKeys
        self.app = app
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
    /// Where the permission monitor runs its probe calls (production: a serial queue of its own, PLT-R730).
    let permissionRunner: any PermissionCheckRunner
    let ruleBox = RuleSetBox()
    /// Since-launch observations the integration hooks report (tap recoveries, first key after a secure-input
    /// release); shared with every tap session's pipeline.
    public let counters = HostCounters()
    let refresh: RefreshRequests
    var inputSourceMonitor: InputSourceMonitor
    var permissionMonitor: PermissionMonitor?
    var secureInputMonitor: SecureInputMonitor?
    var workspaceToken: (any ObservationToken)?
    var drainTimer: (any ScheduledTimer)?
    var retryTimer: (any ScheduledTimer)?
    /// Bumped on every schedule and cancel; a fire whose hop to main carries an older value is stale.
    var retryGeneration: UInt64 = 0
    /// A timeout disabled the tap; its re-enable counts as a recovery for the integration hooks (QA-R11).
    var timeoutRecoveryPending = false

    var lifecycle = HostLifecycle()
    var lifecycleGeneration: UInt64 = 0
    var pendingInputs: [LifecycleInput] = []
    var processingInputs = false
    var session: TapSession?
    /// A removed session whose thread may still be exiting; its echoes are retired before the next tap.
    var retiredSession: TapSession?
    /// The retired session's thread never entered its run loop (its creation failed or timed out), so no callback of
    /// it can be running; it is waited for only briefly (`TapSession.abandonedExitTimeout`).
    var retiredSessionNeverRan = false
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
    /// The bundled collision list, set on the utility queue at start, read by the learning tracker on main.
    let collisionWords = CollisionVocabularyBox()
    /// Hands the ax thread's memory documents to the settings store in order (PLT-R392).
    var appModesRecorder: AppModesRecorder?
    var inactiveReasons: Set<SessionInactiveReason> = []

    public internal(set) var state: HostState = .starting

    public var onEvent: (@MainActor (HostEvent) -> Void)?

    /// Production wiring: the real tap thread and pipeline, the main dispatch queue for hops, the uptime clock
    /// for everything that shares a base with the tap's event timestamps.
    public convenience init(dependencies: InputHostDependencies, settingsStore: SettingsStore) {
        var dependencies = dependencies
        if dependencies.signposts == nil {  // PLT-R802: in all builds; the subsystem comes from the bundle
            dependencies.signposts = Bundle.main.bundleIdentifier.map { PlatformSignposts(subsystem: $0) }
        }
        self.init(
            dependencies: dependencies, settingsStore: settingsStore, hop: DispatchMainHop(),
            makeTapThread: TapSession.productionThreadMaker(factory: dependencies.tapFactory), tapClock: MachClock(),
            loadBundled: TapSettingsPublisher.bundledLoader, macOSVersion: Self.macOSVersion,
            runsWorkerThread: true, mainSignalQueue: .main,
            permissionRunner: QueuePermissionCheckRunner(
                queue: DispatchQueue(label: (Bundle.main.bundleIdentifier ?? "host") + ".permissions", qos: .utility)))
    }

    init(
        dependencies: InputHostDependencies, settingsStore: SettingsStore, hop: any MainThreadHop,
        makeTapThread: @escaping TapThreadMaker, tapClock: any MonotonicClock,
        loadBundled: @escaping TapSettingsPublisher.BundledResourcesLoader, macOSVersion: LooseVersion,
        runsWorkerThread: Bool, mainSignalQueue: DispatchQueue? = nil,
        permissionRunner: any PermissionCheckRunner = InlinePermissionCheckRunner()
    ) {
        self.permissionRunner = permissionRunner
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
        // ADR 0303: tap -> main wakes on the main queue in production; tests keep the utility queue (nil), where
        // `ManualMainHop` collects the drains.
        channels = HostChannels(
            initial: initial, marker: .random(), signalQueue: dependencies.utilityQueue,
            mainSignalQueue: mainSignalQueue ?? dependencies.utilityQueue)
        axThread = RunLoopThread(name: "ax", qualityOfService: .userInitiated)
        let refresh = self.refresh
        focusTracker = FocusTracker(
            thread: axThread,
            ax: FocusChangeSignalingAXProvider(base: dependencies.ax, thread: axThread) { refresh.request() },
            processes: dependencies.processes, output: channels.snapshots.focus,
            generation: channels.focusGeneration, inbox: channels.outbox.toAX, metrics: dependencies.metrics,
            health: dependencies.health, clock: dependencies.clock, macOSVersion: macOSVersion,
            capture: dependencies.capture, signposts: dependencies.signposts, scheduler: dependencies.scheduler)
        // A settle re-read or an observer retry publishes without a notification: wake the main thread the same way.
        focusTracker.setDeferredPublicationObserver { refresh.request() }
        worker = InjectionWorker(
            queue: channels.queue, signal: channels.workerSignal, feedback: channels.feedback,
            marker: channels.marker, focusGeneration: channels.focusGeneration,
            services: InjectionServices(
                poster: dependencies.poster, fieldAccess: dependencies.fieldAccess, pasteboard: dependencies.pasteboard,
                clock: tapClock, metrics: dependencies.metrics, health: dependencies.health,
                logger: dependencies.logger, capture: dependencies.capture, signposts: dependencies.signposts))
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
        // ENG-R865: every change of the learned memory's votes reaches the engines through the publisher, which keeps
        // the settings revision so the tap swaps at a hard boundary.
        let publisher = settingsPublisher
        settingsStore.collisionMemory.setObserver { votes in
            publisher.collisionMemoryChanged(CollisionMemoryBridge.snapshot(votes))
        }
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
        let memory = settingsStore.collisionMemory
        let collisionWords = self.collisionWords
        dependencies.utilityQueue.sync {
            publisher.preloadResources()
            // PLT-R914: the memory is validated against the bundled list and loaded before the first catalog, so the
            // first engines already carry it. Crash-loop safe mode touches no file (PLT-R1009). Without the bundled
            // list (it failed to load) the memory stays unloaded: nothing is recorded and the file is never
            // rewritten (PLT-R1006).
            if let vocabulary = publisher.collisionVocabulary() {
                collisionWords.set(vocabulary)
                if !settings.safeMode { memory.load(vocabulary: vocabulary) }
            }
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

    /// The current layout's key table (PLT-R360), for the hotkey recorder and the latency probe.
    public func currentLayoutTable() -> LayoutTable? { channels.snapshots.inputSource.load().table }

    /// Enabled input sources (IDs and names), for the layout binding in Settings (PLT-R373).
    public func enabledInputSources() -> [InputSourceInfo] { dependencies.inputSources.enabledSources() }

    /// Immediate secure-input poll when the menu opens (PLT-R395).
    public func refreshSecureInput() -> SecureInputSnapshot {
        secureInputMonitor?.pollNow() ?? channels.snapshots.secureInput.load()
    }

    /// Immediate permission check on menu open (PLT-R721), run on the monitor's runner: returns at once with the
    /// newest status known, never waiting for a permission call (PRD-R13, PLT-R730). A change reaches the shell as
    /// `.permissionsChanged` once the check answered.
    public func refreshPermissions() -> PermissionStatus {
        guard let monitor = permissionMonitor else { return latestPermissions ?? Self.unknownPermissions }
        monitor.requestCheck()
        let status = monitor.latest ?? latestPermissions ?? Self.unknownPermissions
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

    /// The guided test of "This app misbehaves" is about to type (`true`) or has finished (`false`)
    /// (PLT-R1205 steps 3-5). While on, the tap passes every keyboard event unchanged without feeding the engine,
    /// hotkeys are suspended so nothing is written to per-app memory and the manual mode stays as it is, and the
    /// composition is reset on entry and exit (PLT-R210). Calls nest; each `true` needs one `false`. The tap reads
    /// the flag from the lifecycle snapshot (PLT-R304: no lock, no allocation).
    public func setDiagnosticsPassThrough(_ on: Bool) {
        guard !stopped else { return }
        feed(.diagnosticsPassThrough(on))
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
