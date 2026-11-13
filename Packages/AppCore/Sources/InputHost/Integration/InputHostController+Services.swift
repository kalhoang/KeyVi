// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Service wiring of `InputHostController`: monitors, signals, workspace events, settings and rules, start and
// stop (PLT-R203 thread map, PLT-R333, PLT-R395, PLT-R399, PLT-R721, PLT-R1008, PRD-R27). Workstream W2-A.

internal import AppModel
internal import CompatRules
internal import Diagnostics
internal import Foundation
internal import Injection
internal import RealtimeSupport
internal import SettingsStore

extension InputHostController {
    /// The tap-log drain runs on main-outbox drains and on this slow timer for records without a notice
    /// (PLT-R803: nothing faster than every 2 s in steady state).
    static let tapLogDrainInterval: Duration = .seconds(30)

    func makeMonitors() {
        let hop = self.hop
        permissionMonitor = PermissionMonitor(
            probe: dependencies.permissions, store: dependencies.keyValueStore, scheduler: dependencies.scheduler
        ) { [weak self] status in hop.hop { self?.permissionsChanged(status) } }
        let cell = channels.snapshots.secureInput
        let refresh = self.refresh
        let ruleBox = self.ruleBox
        let publish: @Sendable (SecureInputSnapshot) -> Void = { snapshot in
            cell.publish(snapshot)
            refresh.request()
        }
        secureInputMonitor = SecureInputMonitor(
            probe: dependencies.secureInput, processes: dependencies.processes,
            hintKey: { ruleBox.hintKey(for: $0) }, scheduler: dependencies.scheduler, publish: publish)
    }

    /// Tap -> main notices hop to the main actor; tap -> ax notices are drained by the focus tracker on the ax
    /// thread (PLT-R382 goes through the inbox, never through `revalidate()`, W1-E request).
    func connectSignals() {
        let hop = self.hop
        channels.mainRelay.connect { [weak self] in hop.hop { self?.drainMainOutbox() } }
        let tracker = focusTracker
        let axThread = self.axThread
        let refresh = self.refresh
        channels.axRelay.connect {
            tracker.drainInbox()
            axThread.perform { refresh.request() }
        }
    }

    func startServices(rules: RulesLoadResult, settings: SettingsState) {
        axThread.start()
        let assembly = installRules(rules: rules, settings: settings)
        let effective = settings.effective
        let recorder = AppModesRecorder(store: settingsStore)  // in emission order (PLT-R392)
        appModesRecorder = recorder
        focusTracker.setMemoryObserver { document in recorder.record(document) }
        focusTracker.update(settings: effective, appModes: settings.appModes)
        focusTracker.start(
            rules: assembly.ruleSet,
            memory: AppModeMemory(
                document: settings.appModes, rememberPerApp: effective.rememberPerApp,
                firstSeen: effective.firstSeenAppMode))
        inputSourceMonitor.apply(binding: LayoutBindingConfiguration(effective.layoutBinding))
        inputSourceMonitor.start()
        if runsWorkerThread { worker.start() }
        secureInputMonitor?.start()
        workspaceToken = dependencies.workspace.observe { [weak self] event in self?.handle(event) }
        let drainer = tapLogDrainer
        drainTimer = dependencies.scheduler.scheduleRepeating(
            every: Self.tapLogDrainInterval, leeway: Self.tapLogDrainInterval / 10
        ) { drainer.drain() }
        permissionMonitor?.start()
        refreshAfterAXWork()
    }

    func stopServices() {
        cancelRetry()
        drainTimer?.cancel()
        drainTimer = nil
        if let current = session {
            current.remove()
            _ = current.thread.waitUntilExited(timeout: TapSession.previousExitTimeout)
            session = nil
        }
        workspaceToken?.cancel()
        workspaceToken = nil
        permissionMonitor?.stop()
        secureInputMonitor?.stop()
        inputSourceMonitor.stop()
        focusTracker.stop()
        appModesRecorder?.finish()
        if runsWorkerThread { worker.stop() }
        channels.cancelSignals()
        refresh.connect(nil)
        let drainer = tapLogDrainer
        dependencies.utilityQueue.sync { _ = drainer.drain() }
        axThread.perform { [axThread] in axThread.stop() }
    }

    // MARK: Settings and rules

    func applySettings(_ settings: SettingsState) {
        let publisher = settingsPublisher
        dependencies.utilityQueue.async { publisher.publish(settings) }
        let effective = settings.effective
        focusTracker.update(settings: effective, appModes: settings.appModes)
        if let rules, RuleSetInputs(settings: settings) != ruleInputs {
            focusTracker.update(rules: installRules(rules: rules, settings: settings).ruleSet)
        }
        inputSourceMonitor.apply(binding: LayoutBindingConfiguration(effective.layoutBinding))
        refreshAfterAXWork()
    }

    /// Compiles and records the rule set; a shipped-file or override problem becomes one health event
    /// (PLT-R503, PLT-R540).
    @discardableResult
    func installRules(rules: RulesLoadResult, settings: SettingsState) -> RuleSetAssembly {
        let inputs = RuleSetInputs(settings: settings)
        let assembly = RuleSetAssembly.build(rules: rules, inputs: inputs)
        ruleInputs = inputs
        ruleBox.set(assembly.ruleSet)
        if assembly.needsHealthEvent {
            let count = assembly.rejectedOverrides.count + (assembly.error == nil ? 0 : 1)
            dependencies.health.record(
                HealthEvent(kind: .ruleLoadError, at: dependencies.wallClock.now(), detail: .count(count)))
        }
        if rules.usedEmbeddedDefaults {
            dependencies.logger.log(.rules(.invalidShippedFileUsingEmbeddedDefaults), level: .error)
        }
        return assembly
    }

    // MARK: Workspace and permissions

    func handle(_ event: WorkspaceEvent) {
        switch event {
        case .applicationActivated:
            focusTracker.revalidate()  // PLT-R381: activation rescans overlays and revalidates focus
            refreshAfterAXWork()
        case .willSleep: setInactive(.asleep, true)
        case .screenLocked: setInactive(.screenLocked, true)
        case .sessionResignedActive: setInactive(.sessionResigned, true)
        case .didWake:
            feedFreshPermissions()
            setInactive(.asleep, false)
            focusTracker.revalidate()
            refreshAfterAXWork()
            session?.watchdog.checkNow()
        case .screenUnlocked:
            feedFreshPermissions()
            setInactive(.screenLocked, false)
        case .sessionBecameActive:
            feedFreshPermissions()
            setInactive(.sessionResigned, false)
            session?.watchdog.checkNow()
        }
    }

    func permissionsChanged(_ status: PermissionStatus) {
        let previous = latestPermissions
        latestPermissions = status
        feed(.permissionsChanged(status))
        onEvent?(.permissionsChanged(status))
        // PLT-R331: a permission change is one of the watchdog's check points; a tap the system left disabled
        // during the change (status still ready) runs the PLT-R330 procedure now, not at the next 5 s tick.
        if previous != nil, previous != status { session?.watchdog.checkNow() }
    }

    /// Queues a state refresh behind the work already queued on the ax thread, so it reads the snapshot that
    /// work published.
    func refreshAfterAXWork() {
        let refresh = self.refresh
        axThread.perform { refresh.request() }
    }

    /// PLT-R399: other Vietnamese input apps (bundle IDs from the rules resource) and enabled built-in Vietnamese
    /// sources, reported once per launch. The launch scan runs on the utility queue.
    func detectConflicts() {
        let scan = conflictScan()
        let hop = self.hop
        dependencies.utilityQueue.async { [weak self] in
            let found = scan()
            hop.hop { self?.reportConflicts(found) }
        }
    }

    /// PRD-R40 screen 5 "Kiểm tra lại" and the diagnostics report (PLT-R1202): a fresh scan, run on the main
    /// actor because it answers a user action. Updates the list the report and onboarding read; the
    /// once-per-launch notice is never repeated.
    @discardableResult
    public func rescanConflicts() -> [ConflictingInput] {
        conflicts = conflictScan()()
        conflictsRescanned = true
        return conflicts
    }

    private func conflictScan() -> @Sendable () -> [ConflictingInput] {
        let sources = dependencies.inputSources.enabledSources()
        let conflicting = ruleBox.ruleSet?.conflictingInputApps ?? []
        let processes = dependencies.processes
        return {
            ConflictDetector.detect(
                running: processes.runningApplications(), enabledSources: sources, conflictingApps: conflicting)
        }
    }

    func reportConflicts(_ found: [ConflictingInput]) {
        // A user rescan that ran while the launch scan was in flight is newer; keep it.
        if !conflictsRescanned { conflicts = found }
        guard !found.isEmpty, !conflictsReported else { return }
        conflictsReported = true
        onEvent?(.conflictsDetected(found))
    }
}

extension LayoutBindingConfiguration {
    /// PLT-R373 settings -> the input-source monitor's binding.
    init(_ binding: LayoutModeBinding) {
        self.init(enabled: binding.enabled, vietnamese: Set(binding.vietnamese), english: Set(binding.english))
    }
}
