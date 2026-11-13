// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Focus tracking on the `ax` thread (PLT-R380-R387, PLT-R510, PLT-R520-R523, T6 <= 30 ms p95).

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore

public struct AXFocusedElement: Sendable, Hashable {
    public var pid: Int32
    public var element: AXElementReference
    public init(pid: Int32, element: AXElementReference) {
        self.pid = pid
        self.element = element
    }
}

/// Attributes read on focus change; all bounded reads (PLT-R343). Title and URL only when a rule needs them,
/// and only for matching in memory.
public struct FocusAttributes: Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?  // kAXIdentifierAttribute
    public var domClasses: [String]  // "AXDOMClassList" when exposed
    public var editable: Bool?
    /// Nearest parent first: up to 6 (5.2), or up to the nearest `AXWebArea` when a document URL was requested
    /// and the web area is further up. Matching uses the first 6.
    public var ancestorRoles: [String]
    /// Transient. The `AXURL` of the focused web area (5.5): only when the element is an `AXWebArea` or lies
    /// inside one, never for browser chrome such as the omnibox. The tracker drops it otherwise.
    public var documentURL: String?
    public var windowTitle: String?  // transient
    public init(
        role: String?, subrole: String?, identifier: String?, domClasses: [String], editable: Bool?,
        ancestorRoles: [String], documentURL: String?, windowTitle: String?
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domClasses = domClasses
        self.editable = editable
        self.ancestorRoles = ancestorRoles
        self.documentURL = documentURL
        self.windowTitle = windowTitle
    }
}

public enum AXNotificationKind: String, Sendable, Hashable, CaseIterable {
    case focusedElementChanged  // kAXFocusedUIElementChangedNotification
    case focusedWindowChanged  // kAXFocusedWindowChangedNotification
    case applicationActivated  // kAXApplicationActivatedNotification
    case titleChanged  // kAXTitleChangedNotification (only for titlePattern bundles)
}

public struct AXAttributeRequest: Sendable, Hashable {
    public var includeDocumentURL: Bool
    public var includeWindowTitle: Bool
    public init(includeDocumentURL: Bool, includeWindowTitle: Bool) {
        self.includeDocumentURL = includeDocumentURL
        self.includeWindowTitle = includeWindowTitle
    }
}

/// Accessibility for focus tracking, called only on the ax thread. Production (`SystemAXProvider`):
/// `AXUIElementCreateSystemWide`, `AXUIElementCreateApplication`, `AXUIElementSetMessagingTimeout(…, 0.1)` on
/// every application element and the system-wide element (PLT-R384), `kAXFocusedApplicationAttribute`,
/// `kAXFocusedUIElementAttribute`, `kAXParentAttribute`, `AXObserverCreate` / `AXObserverAddNotification` /
/// `AXObserverGetRunLoopSource`. Never sets `AXEnhancedUserInterface`; sets `AXManualAccessibility` only on
/// request (PLT-R385).
///
/// The system-wide focus is read in two steps so the circuit breaker can stop every query to a slow pid
/// (PLT-R384): the focused application comes from the system-wide element, the focused element from that
/// application's element.
public protocol AXProvider: Sendable {
    /// pid of the system-wide focused application (`kAXFocusedApplicationAttribute`, PLT-R381); nil when none.
    func focusedApplication() -> AXCallResult<Int32?>
    /// The focused element of application `pid` (`kAXFocusedUIElementAttribute`); nil when it has none.
    func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?>
    func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes>
    /// Observer whose run-loop source the caller adds to the ax run loop. The handler runs on the ax thread.
    func observe(
        pid: Int32, notifications: Set<AXNotificationKind>,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)?
    /// `AXManualAccessibility = true` when a rule says `axEnable: manual`; the caller records it (PLT-R385).
    func enableManualAccessibility(pid: Int32) -> Bool
}

/// A registered AXObserver; `invalidate` removes notifications and its run-loop source.
public protocol AXObservation: AnyObject, Sendable {
    var runLoopSource: CFRunLoopSource { get }
    func invalidate()
}

/// Rules as the focus tracker needs them. `RuleSet` conforms (InputHost extension); fakes in TestSupport.
public protocol FocusDecisionResolving: Sendable {
    func resolve(_ context: MatchContext) -> ResolvedDecision
    var overlayBundles: Set<BundleKey> { get }
    var titlePatternBundles: Set<BundleKey> { get }
    func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint
}

/// PLT-R384: 3 timeouts within 10 s for one pid stop AX queries to that pid for 60 s. `recordTimeout` returns
/// true when this timeout opened the breaker (the caller records one health event). Logic:
/// `AXCircuitBreaker+Logic.swift`.
public struct AXCircuitBreaker: Sendable {
    let threshold: Int
    let windowNanoseconds: UInt64
    let cooldownNanoseconds: UInt64
    var recentTimeouts: [Int32: [MonotonicInstant]] = [:]
    var openUntil: [Int32: MonotonicInstant] = [:]

    public init(threshold: Int = 3, window: Duration = .seconds(10), cooldown: Duration = .seconds(60)) {
        self.threshold = max(1, threshold)
        windowNanoseconds = Self.nanoseconds(window)
        cooldownNanoseconds = Self.nanoseconds(cooldown)
    }

    public mutating func recordTimeout(pid: Int32, at: MonotonicInstant) -> Bool { record(pid: pid, at: at) }
    public func isOpen(pid: Int32, at: MonotonicInstant) -> Bool { openUntil[pid].map { at < $0 } ?? false }
}

/// The focus tracker. Owns AXObservers on the focused app and on `overlay` apps (PLT-R380), treats the
/// system-wide AX focus as authoritative (PLT-R381), resolves rules and per-app mode, and publishes a
/// `FocusSnapshot` plus the current generation before the next key is processed (PLT-R391).
///
/// Every public method may be called from any thread: it hops to the ax thread (`RunLoopThread.perform`) and
/// returns. Rules are resolved only when the focus context changes or rules/settings change (PLT-R523). The
/// state lives in `FocusCore` (FocusCore*.swift), confined to the ax thread.
public final class FocusTracker: Sendable {
    let thread: RunLoopThread
    let core: ThreadConfined<FocusCore>
    let mirror = FocusMirror()

    public init(
        thread: RunLoopThread, ax: any AXProvider, processes: any ProcessIdentityProvider,
        output: SnapshotCell<FocusSnapshot>, generation: CurrentFocusGeneration, inbox: SPSCRing<AXNotice>,
        metrics: PlatformMetrics, health: HealthEventLog, clock: any MonotonicClock, macOSVersion: LooseVersion
    ) {
        self.thread = thread
        let services = FocusCore.Services(
            thread: thread, ax: ax, processes: processes, output: output, generation: generation, inbox: inbox,
            metrics: metrics, health: health, clock: clock, macOSVersion: macOSVersion)
        core = ThreadConfined(FocusCore(services: services, mirror: mirror))
    }

    public func start(rules: any FocusDecisionResolving, memory: AppModeMemory) {
        perform { [self] core in core.start(sink: self, rules: rules, memory: memory) }
    }

    public func stop() { perform { $0.stop() } }
    /// Hop to the ax thread; re-resolve the current focus (rules or overrides changed, PLT-R540 acceptance).
    public func update(rules: any FocusDecisionResolving) { perform { $0.update(rules: rules) } }
    public func update(settings: EffectiveSettings, appModes: AppModesDocument) {
        perform { $0.update(settings: settings, appModes: appModes) }
    }

    /// NSWorkspace activation and wake (PLT-R381): rescan overlay apps and revalidate system-wide focus. The
    /// idle-key flag (PLT-R382) arrives through the inbox and revalidates without the rescan.
    public func revalidate() { perform { $0.revalidate(scanOverlays: true) } }
    /// Drains `inbox` (tap toggles first, then revalidation) on the ax thread; wired to the AX wake signal.
    public func drainInbox() { perform { $0.drainInbox() } }

    /// Menu radio or click-to-toggle (D16): same memory update as a hotkey toggle, without a tap sequence
    /// (PRD-R20).
    public func setMode(_ mode: TypingMode) { perform { $0.setMode(mode) } }

    /// Receives every changed `app-modes.json` document (on the ax thread) so the owner can persist it through
    /// `SettingsStore.recordAppModes` (PLT-R392, PRD-R23).
    public func setMemoryObserver(_ observer: (@Sendable (AppModesDocument) -> Void)?) {
        perform { $0.memoryObserver = observer }
    }

    /// Rule decision behind the last published snapshot, for the diagnostics report (any thread).
    public func currentDecision() -> ResolvedDecision? { mirror.decision }

    /// Bundles on which `AXManualAccessibility` was set because a rule asked for it (PLT-R385 "record that it
    /// did"; any thread).
    public func manualAccessibilityBundles() -> Set<BundleKey> { mirror.manualAccessibility }
}

/// Conversion done once per focus change (rule decision -> tap decision), PLT-R386 `byEngine` resolution.
/// A shipped `paste` strategy that needs an opt-in the user has not given falls back to the first non-paste
/// strategy of the rule's chain (PLT-R460). Logic: `HostDecisionMapping.swift`.
public enum HostDecisionMapper {
    public static func map(_ decision: ResolvedDecision, engine: EngineFingerprint, optedIntoPaste: Bool)
        -> HostDecision
    {
        HostDecisionMapping.map(decision, engine: engine, optedIntoPaste: optedIntoPaste)
    }
}
