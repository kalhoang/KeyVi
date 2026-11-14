// SPDX-License-Identifier: GPL-3.0-or-later
//
// ax-thread state of `FocusTracker` (PLT-R380-R393, PLT-R523). Created by the tracker, then touched only inside
// `ThreadConfined.withValue` blocks performed on the ax `RunLoopThread`; never shared with another thread.

import AppModel
import CompatRules
import Diagnostics
import Dispatch
import Foundation
import Injection
import RealtimeSupport
import SettingsStore

/// Routes AX observer callbacks back onto the ax thread (implemented by `FocusTracker`).
protocol FocusNotificationSink: AnyObject, Sendable {
    func axNotification(pid: Int32, kind: AXNotificationKind)
    /// A settle re-read or an observer retry is due (`FocusCore+Settle.swift`); called on the scheduler's queue.
    func deferredWorkDue(_ work: FocusDeferredWork)
}

/// What one `refresh` did.
enum FocusRefreshOutcome: Equatable {
    /// An idle or settle read timed out for the current owner: nothing was resolved or published.
    case learnedNothing
    /// The context is the one already published (nothing published, no T6 sample).
    case unchanged
    case published
}

/// What the last published snapshot was built from. `match` holds the transient title and URL for change
/// detection only; they never leave this thread (PLT-R383).
struct FocusContext {
    var pid: Int32?
    var element: AXElementReference?
    var identity: ProcessIdentity?
    var match: MatchContext
    var decision: ResolvedDecision
    var resolution: ModeResolution
    var snapshot: FocusSnapshot
}

/// The parts of a snapshot whose change is a hard boundary (PLT-R340): app, field, decision, mode and pause.
/// The mode's source is not one: an app's first focus records its mode, so the next resolution reports the same
/// mode as `remembered` instead of `globalMode` or `ruleDefault`. Nor is the app's source (PLT-R381 amendment): the
/// same process, first taken from the frontmost application and then named by AX without a focused element (or the
/// reverse), is the same app with the same missing field, so only the label is republished.
struct FocusSnapshotContent: Hashable {
    var app: FocusedApp?
    var field: FieldContext
    var decision: HostDecision
    var mode: TypingMode
    var pause: PauseReason?

    init(_ snapshot: FocusSnapshot) {
        app = snapshot.app.map {
            FocusedApp(pid: $0.pid, bundle: $0.bundle, appVersion: $0.appVersion, engine: $0.engine)
        }
        field = snapshot.field
        decision = snapshot.decision
        mode = snapshot.mode
        pause = snapshot.pause
    }
}

struct FingerprintKey: Hashable {
    var bundlePath: String
    var buildVersion: String?
}

final class FocusCore {
    struct Services: Sendable {
        var thread: RunLoopThread
        var ax: any AXProvider
        var processes: any ProcessIdentityProvider
        var output: SnapshotCell<FocusSnapshot>
        var generation: CurrentFocusGeneration
        var inbox: SPSCRing<AXNotice>
        var metrics: PlatformMetrics
        var health: HealthEventLog
        var clock: any MonotonicClock
        var macOSVersion: LooseVersion
        /// PLT-R905 typing trace: focus snapshots (roles and bundle IDs) while a capture runs.
        var capture: CaptureController?
        /// PLT-R802: an `axCall` interval around every focus-tracking AX call.
        var signposts: PlatformSignposts?
        /// Settle re-reads and observer retries (`FocusCore+Settle.swift`); nil defers nothing.
        var scheduler: (any TimerScheduler)?
    }

    let services: Services
    let mirror: FocusMirror
    weak var sink: (any FocusNotificationSink)?
    var memoryObserver: (@Sendable (AppModesDocument) -> Void)?
    var rules: (any FocusDecisionResolving)?
    var memory = AppModeMemory(document: AppModesDocument(), rememberPerApp: true, firstSeen: .inherit)
    var settings = DefaultSettings.v1
    var breaker = AXCircuitBreaker()
    var observed: [Int32: ObservedApplication] = [:]
    var overlayPIDs: [Int32: BundleKey] = [:]
    var fingerprints: [FingerprintKey: EngineFingerprint] = [:]
    var current: FocusContext?
    var sessionMode: SessionMode?
    var appliedToggleSequence: UInt64 = 0
    var generation = FocusGeneration.initial
    var fieldToken: UInt64 = 0
    var lastEmittedDocument: AppModesDocument?
    var emittedHistory = EmittedModeHistory()
    var manualAccessibilityPIDs: Set<Int32> = []
    var deferred = FocusDeferredState()
    var running = false

    init(services: Services, mirror: FocusMirror) {
        self.services = services
        self.mirror = mirror
    }

    func start(sink: any FocusNotificationSink, rules: any FocusDecisionResolving, memory: AppModeMemory) {
        self.sink = sink
        self.rules = rules
        self.memory = memory
        let document = memory.document()
        lastEmittedDocument = document
        emittedHistory.record(document)
        running = true
        syncObservers(scanOverlays: true)
        refresh(force: true)
    }

    func stop() {
        running = false
        cancelDeferredWork()
        for pid in Array(observed.keys) { removeObserver(pid) }
        overlayPIDs = [:]
        current = nil
        sessionMode = nil
    }

    func update(rules: any FocusDecisionResolving) {
        self.rules = rules
        fingerprints = [:]  // the webkitBrowsers group may have changed (PLT-R510)
        guard running else { return }
        syncObservers(scanOverlays: true)
        refresh(force: true)
    }

    func update(settings: EffectiveSettings, appModes: AppModesDocument) {
        self.settings = settings
        emittedHistory.acknowledge(appModes)
        memory = AppModeMemory.merged(
            current: memory, incoming: appModes, recentlyEmitted: emittedHistory,
            rememberPerApp: settings.rememberPerApp, firstSeen: settings.firstSeenAppMode)
        emitMemoryIfChanged()
        guard running else { return }
        refresh(force: true)
    }

    /// `scanOverlays`: NSWorkspace activation and wake rescan running overlay apps (a full process scan in
    /// production). The PLT-R382 idle-key revalidation does not: it runs on the first key after every typing
    /// pause, competes with the T6 budget, and an overlay app that launches activates and triggers a scan.
    /// An activation or wake also opens a settle window: the new owner's focused element may not be readable yet.
    func revalidate(scanOverlays: Bool) {
        guard running else { return }
        if scanOverlays { syncObservers(scanOverlays: true) }
        refresh(force: false, idle: !scanOverlays)
        if scanOverlays { scheduleSettleUnlessTimedOut() }
    }

    /// The read happens now; the settle window reads again in case the app posted before its focus was readable.
    func handleNotification(pid: Int32, kind: AXNotificationKind) {
        guard running else { return }
        refresh(force: false)
        scheduleSettleUnlessTimedOut()
    }

    /// Reads the system-wide focus and, when the context changed (or `force`), resolves once and publishes
    /// (PLT-R391, PLT-R523). Records T6 (`focusRefresh`).
    ///
    /// `idle` is the PLT-R382 revalidation on the first key after a typing pause. When it learns nothing it
    /// publishes nothing: a generation bump would reset the word in progress and make the worker discard edits
    /// in flight (PLT-R316). An AX timeout for the current owner teaches nothing about the focus, so the snapshot
    /// stays until the breaker opens (PLT-R384), which then publishes the `timedOut` context.
    ///
    /// `ifMoved` (PLT-R389 trigger and overlay reads): when the focused app and element are the published ones the
    /// element's attributes are not read and nothing changes. A Command+C or a click then costs two AX messages
    /// instead of the attribute walk; a change of the same element's attributes is left to notifications and to
    /// the PLT-R382 read after a pause.
    @discardableResult
    func refresh(force: Bool, idle: Bool = false, ifMoved: Bool = false) -> FocusRefreshOutcome {
        guard running, let rules else { return .unchanged }
        let started = services.clock.now()
        let reading = readFocus(rules: rules, at: started, ifMoved: ifMoved)
        deferred.lastReadTimedOut = reading.availability == .timedOut
        if idle, learnedNothing(from: reading, at: started) { return .learnedNothing }
        if reading.elementUnmoved { return .unchanged }
        let match = matchContext(for: reading)
        let sameElement = current.map { $0.pid == reading.pid && $0.element == reading.element?.element } ?? false
        let sameSource = current?.snapshot.app?.source == reading.appSource
        if !force, sameElement, sameSource, current?.match == match { return .unchanged }
        let decision = rules.resolve(match)
        recordSideEffects(of: decision, reading: reading)
        let published = resolveAndPublish(
            reading: reading, match: match, decision: decision, sameElement: sameElement, at: started)
        services.metrics.focusRefresh.record(nanoseconds: services.clock.now().nanoseconds(since: started))
        return published ? .published : .unchanged
    }

    /// A timeout of the system-wide read (no pid), or of the current owner's element read while its breaker is
    /// still closed.
    private func learnedNothing(from reading: FocusReading, at instant: MonotonicInstant) -> Bool {
        guard reading.availability == .timedOut, current != nil else { return false }
        guard let pid = reading.pid else { return true }
        return pid == current?.pid && !breaker.isOpen(pid: pid, at: instant)
    }

    /// True when a snapshot was published.
    private func resolveAndPublish(
        reading: FocusReading, match: MatchContext, decision: ResolvedDecision, sameElement: Bool,
        at instant: MonotonicInstant
    ) -> Bool {
        let bundle = reading.identity?.bundle
        if reading.pid != current?.pid || bundle != current?.identity?.bundle {
            sessionMode = nil  // PRD-R21: rules and memory win on every activation
            observeOwner(pid: reading.pid, bundle: bundle)
        }
        let resolution = memory.activate(bundle: bundle, ruleDefault: decision.defaultMode)
        emitMemoryIfChanged()
        let optedIn = decision.source == .user || decision.rule.map(settings.optedInRules.contains) == true
        var hostDecision = HostDecisionMapper.map(decision, engine: reading.engine, optedIntoPaste: optedIn)
        if resolution.ignored { hostDecision = HostDecisionMapping.ignoring(hostDecision) }
        let field = fieldContext(for: reading)
        let (mode, source) = effectiveMode(resolution, bundle: bundle)
        let app = reading.identity.map {
            FocusedApp(
                pid: $0.pid, bundle: $0.bundle, appVersion: match.appVersion, engine: reading.engine,
                source: reading.source)
        }
        var snapshot = FocusSnapshot(
            generation: generation, app: app, field: field, decision: hostDecision, mode: mode, modeSource: source,
            appliedToggleSequence: appliedToggleSequence, fieldHandle: current?.snapshot.fieldHandle,
            changedAt: current?.snapshot.changedAt ?? instant,
            pause: TextFocusGate.pause(field: field, decision: hostDecision))
        if sameElement, let current, FocusSnapshotContent(current.snapshot) == FocusSnapshotContent(snapshot) {
            let appRelabelled = snapshot.app?.source != current.snapshot.app?.source
            let sourceChanged = appRelabelled || snapshot.modeSource != current.snapshot.modeSource
            if sourceChanged { services.output.publish(snapshot) }
            #if DEV_RECORDER
            if appRelabelled { recordDevFocus(snapshot, at: instant) }  // PLT-R904A: `bundle` or `front` follows
            #endif
            self.current?.match = match
            self.current?.decision = decision
            self.current?.resolution = resolution
            self.current?.snapshot = snapshot
            mirror.update(decision: decision)
            return sourceChanged
        }
        stampNewGeneration(&snapshot, element: reading.element, sameElement: sameElement, at: instant)
        // The generation first: the worker discards edits built for an older one (PLT-R316).
        services.generation.store(generation)
        services.output.publish(snapshot)
        recordFocusCapture(snapshot, at: instant)
        mirror.update(decision: decision)
        current = FocusContext(
            pid: reading.pid, element: reading.element?.element, identity: reading.identity, match: match,
            decision: decision, resolution: resolution, snapshot: snapshot)
        return true
    }

    /// PLT-R905: every focus change goes into a running typing trace with roles and the bundle ID only, never
    /// titles or URLs (the record type has no field for them).
    private func recordFocusCapture(_ snapshot: FocusSnapshot, at instant: MonotonicInstant) {
        #if DEV_RECORDER
        recordDevFocus(snapshot, at: instant)  // PLT-R904A
        #endif
        guard let capture = services.capture, capture.isRecording else { return }
        let record = CaptureRecord.focus(
            bundle: snapshot.app?.bundle, role: snapshot.field.role, subrole: snapshot.field.subrole, at: instant)
        _ = capture.focusRecords.push(record)
    }

    /// contracts.md 10.4: the token names the element. A republication for the same element (rule or settings
    /// re-resolution, changed attributes) keeps it and the focus time, so the tap does not see a focus change;
    /// every element change mints a new one (PLT-R340, PLT-R408).
    private func stampNewGeneration(
        _ snapshot: inout FocusSnapshot, element: AXFocusedElement?, sameElement: Bool, at instant: MonotonicInstant
    ) {
        generation = generation.next
        snapshot.generation = generation
        if !sameElement {
            fieldToken &+= 1
            snapshot.changedAt = instant
        }
        snapshot.fieldHandle = element.map { FieldHandle(pid: $0.pid, token: fieldToken, element: $0.element) }
    }

    /// PLT-R521 tie health event; PLT-R385 `AXManualAccessibility` only when the rule asks, recorded once per pid.
    private func recordSideEffects(of decision: ResolvedDecision, reading: FocusReading) {
        let bundle = reading.identity?.bundle
        if decision.tieLoser != nil {
            services.health.record(HealthEvent(kind: .ruleTie, at: Date(), bundle: bundle, rule: decision.rule))
        }
        guard decision.axEnable == .manual, let pid = reading.pid, !manualAccessibilityPIDs.contains(pid) else {
            return
        }
        if services.ax.enableManualAccessibility(pid: pid) {
            manualAccessibilityPIDs.insert(pid)
            if let bundle { mirror.recordManualAccessibility(bundle) }
        }
    }

    private func fieldContext(for reading: FocusReading) -> FieldContext {
        let attributes = reading.attributes
        return FieldContext(
            axAvailability: reading.availability, role: attributes?.role, subrole: attributes?.subrole,
            identifier: attributes?.identifier, domClasses: attributes?.domClasses ?? [],
            editable: attributes?.editable, secure: attributes?.subrole == TextFocusGate.secureSubrole)
    }
}

extension FocusTracker: FocusNotificationSink {
    func axNotification(pid: Int32, kind: AXNotificationKind) {
        perform { $0.handleNotification(pid: pid, kind: kind) }
    }

    func deferredWorkDue(_ work: FocusDeferredWork) {
        perform { $0.runDeferred(work) }
    }

    /// Always asynchronous, also from the ax thread itself, so a block never runs nested inside another.
    func perform(_ work: @escaping @Sendable (FocusCore) -> Void) {
        let core = self.core
        thread.perform { core.withValue { work($0) } }
    }

    /// Waits until every block queued so far has run on the ax thread (tests and orderly shutdown). Must not be
    /// called on the ax thread.
    func waitUntilIdle() {
        let semaphore = DispatchSemaphore(value: 0)
        thread.perform { semaphore.signal() }
        semaphore.wait()
    }
}
