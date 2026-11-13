// SPDX-License-Identifier: LicenseRef-App-Pending
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
public protocol PermissionProbe: Sendable {
    func isAccessibilityTrusted() -> Bool
    func canPostEvents() -> Bool
    func canListenToEvents() -> Bool
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
    /// Input Monitoring needed: tap could not be created or receives no keys while Accessibility is granted.
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
    /// Onboarding polls every 1 s for at most 5 minutes while visible (PLT-R711).
    public func setFastPolling(_ enabled: Bool) { updateFastPolling(enabled) }
    /// The lifecycle reports that the tap could not be created or receives no keys. With Accessibility granted
    /// and `CGPreflightListenEventAccess()` false this sets `listenEventRequired` (PLT-R702).
    public func setTapUnavailable(_ unavailable: Bool) { updateTapUnavailable(unavailable) }
}

/// "Đặt lại quyền" (PLT-R740): runs `/usr/bin/tccutil reset Accessibility <own bundle ID>` after the user
/// confirms. Never automatic, never without a bundle ID (PLT-R741), never with sudo.
public protocol PermissionResetting: Sendable {
    func resetAccessibility(bundleIdentifier: String) throws
}
