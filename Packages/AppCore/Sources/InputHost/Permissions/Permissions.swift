// SPDX-License-Identifier: GPL-3.0-or-later
//
// Permissions (PLT-R701-R741). Probes are cheap system calls made off the tap thread.

public import AppModel
internal import Foundation
public import RealtimeSupport
public import SettingsStore

/// Production (`SystemPermissionProbe`): `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()`,
/// `CGPreflightListenEventAccess()`, `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
/// `CGRequestListenEventAccess()`, `CGRequestPostEventAccess()`; the signing identity digest comes from
/// `SecCodeCopySelf` + `SecCodeCopyDesignatedRequirement`.
///
/// PLT-R701: `AXIsProcessTrusted()` follows the switch live. The two CoreGraphics preflights keep the answer they
/// had when the process started (Apple DTS on the developer forums, threads 727984 and 720840), so they never
/// decide on their own that a permission is still missing; `canListenToEventsNow()` is the live Input Monitoring
/// check.
public protocol PermissionProbe: Sendable {
    func isAccessibilityTrusted() -> Bool
    func canPostEvents() -> Bool
    /// `CGPreflightListenEventAccess()`: the Input Monitoring answer at launch.
    func canListenToEvents() -> Bool
    /// PLT-R702, PLT-R731: Input Monitoring as it is now, by creating a listen-only key tap and releasing it at
    /// once (a passive tap never holds keys back). Creating a tap for keys can make macOS prompt for Input
    /// Monitoring, so the monitor calls this only once it knows the tap needs that permission.
    func canListenToEventsNow() -> Bool
    func promptForAccessibility()
    func requestListenEventAccess() -> Bool
    func requestPostEventAccess() -> Bool
    /// Digest of the designated requirement, to detect `stale` grants after OS updates (PLT-R720).
    func signingIdentityDigest() -> String?
}

public struct PermissionStatus: Sendable, Hashable {
    public enum Health: String, Sendable, Hashable { case ready, noPermission, stale }
    public var accessibility: PermissionState
    public var postEvent: PermissionState
    public var listenEvent: PermissionState
    /// Input Monitoring needed and still missing: the tap could not be created while Accessibility is granted and
    /// neither the launch-time preflight nor the live check sees Input Monitoring (PLT-R702).
    public var listenEventRequired: Bool
    public var health: Health
    public init(
        accessibility: PermissionState, postEvent: PermissionState, listenEvent: PermissionState,
        listenEventRequired: Bool, health: Health
    ) {
        self.accessibility = accessibility
        self.postEvent = postEvent
        self.listenEvent = listenEvent
        self.listenEventRequired = listenEventRequired
        self.health = health
    }
}

/// Every 2 s while not ready, every 30 s while ready (timers from the injected scheduler, utility queue in
/// production), immediately on wake, session activation and menu open (PLT-R721). Remembers the identity digest
/// of the last grant (key-value store) for `stale`.
///
/// `onChange` runs for the first check after `start()` and then whenever the status changes, in check order,
/// one at a time and outside the check lock: it may call back into the monitor (`checkNow`, `setTapUnavailable`);
/// a status produced meanwhile is delivered after it returns. Logic: `PermissionMonitor+Checks.swift`.
public final class PermissionMonitor: Sendable {
    public static let notReadyInterval: TimeSpan = .seconds(2)
    public static let readyInterval: TimeSpan = .seconds(30)
    public static let onboardingInterval: TimeSpan = .seconds(1)
    /// PLT-R711: fast polling stops by itself after 5 minutes.
    public static let onboardingLimit: TimeSpan = .seconds(300)
    /// `KeyValueStore` key of the last granted identity (a 52-bit hash of the designated requirement digest).
    public static let lastGrantedDigestKey = "PermissionLastGrantedIdentity"

    let probe: any PermissionProbe
    let store: any KeyValueStore
    let scheduler: any TimerScheduler
    let delivery: OrderedDelivery<PermissionStatus>
    let state = Mutex(PermissionMonitorState())

    public init(
        probe: any PermissionProbe, store: any KeyValueStore, scheduler: any TimerScheduler,
        onChange: @escaping @Sendable (PermissionStatus) -> Void
    ) {
        self.probe = probe
        self.store = store
        self.scheduler = scheduler
        self.delivery = OrderedDelivery(onChange)
    }

    public func start() { beginChecks() }
    public func stop() { endChecks() }
    public func checkNow() -> PermissionStatus { check() }
    /// The status of the most recent check, already set while an older status is still being delivered. A receiver
    /// that forwards statuses compares the one in hand with this and drops it when a newer one is queued behind it,
    /// so a `ready` replaced during its own delivery (the tap it allowed failed, PLT-R702) never reaches the UI
    /// after its replacement (PRD-R40 screen 2). `nil` before the first check.
    public var latest: PermissionStatus? { state.withLock { $0.last } }
    /// Onboarding polls every 1 s for at most 5 minutes while visible (PLT-R711).
    public func setFastPolling(_ enabled: Bool) { updateFastPolling(enabled) }
    /// The lifecycle reports that the tap could not be created. With Accessibility granted and Input Monitoring
    /// missing (launch-time preflight and live check) this sets `listenEventRequired` (PLT-R702); the live check
    /// clears it when the user turns Input Monitoring on while the app runs (PLT-R731).
    public func setTapUnavailable(_ unavailable: Bool) { updateTapUnavailable(unavailable) }
}

extension PermissionProbe {
    /// Probes without a live check (fakes, wrappers) answer with the launch-time preflight.
    public func canListenToEventsNow() -> Bool { canListenToEvents() }
}

/// "Đặt lại quyền" (PLT-R740): runs `/usr/bin/tccutil reset Accessibility <own bundle ID>` after the user
/// confirms. Never automatic, never without a bundle ID (PLT-R741), never with sudo.
public protocol PermissionResetting: Sendable {
    func resetAccessibility(bundleIdentifier: String) throws
}
