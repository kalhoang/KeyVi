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
    public var ancestorRoles: [String]  // up to 6 parents (5.2)
    public var documentURL: String?  // transient
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
public protocol AXProvider: Sendable {
    func systemWideFocus() -> AXCallResult<AXFocusedElement?>
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

/// PLT-R384: 3 timeouts within 10 s for one pid stop AX queries to that pid for 60 s.
public struct AXCircuitBreaker: Sendable {
    public init(threshold: Int = 3, window: Duration = .seconds(10), cooldown: Duration = .seconds(60)) { unimplemented() }
    public mutating func recordTimeout(pid: Int32, at: MonotonicInstant) -> Bool { unimplemented() }
    public func isOpen(pid: Int32, at: MonotonicInstant) -> Bool { unimplemented() }
}

/// The focus tracker. Owns AXObservers on the focused app and on `overlay` apps (PLT-R380), treats the
/// system-wide AX focus as authoritative (PLT-R381), resolves rules and per-app mode, and publishes a
/// `FocusSnapshot` plus the current generation before the next key is processed (PLT-R391).
public final class FocusTracker: Sendable {
    public init(
        thread: RunLoopThread, ax: any AXProvider, processes: any ProcessIdentityProvider,
        output: SnapshotCell<FocusSnapshot>, generation: CurrentFocusGeneration, inbox: SPSCRing<AXNotice>,
        metrics: PlatformMetrics, health: HealthEventLog, clock: any MonotonicClock, macOSVersion: LooseVersion
    ) { unimplemented() }

    public func start(rules: any FocusDecisionResolving, memory: AppModeMemory) { unimplemented() }
    public func stop() { unimplemented() }
    /// Hop to the ax thread; re-resolve the current focus (rules or overrides changed, PLT-R540 acceptance).
    public func update(rules: any FocusDecisionResolving) { unimplemented() }
    public func update(settings: EffectiveSettings, appModes: AppModesDocument) { unimplemented() }
    /// NSWorkspace activation, wake, idle-key flag (PLT-R381, PLT-R382): revalidate system-wide focus.
    public func revalidate() { unimplemented() }
    /// Drains `inbox` (tap toggles first, then revalidation) on the ax thread; wired to the AX wake signal.
    public func drainInbox() { unimplemented() }
}

/// Conversion done once per focus change (rule decision -> tap decision), PLT-R386 `byEngine` resolution.
public enum HostDecisionMapper {
    public static func map(_ decision: ResolvedDecision, engine: EngineFingerprint, optedIntoPaste: Bool) -> HostDecision {
        unimplemented()
    }
}

