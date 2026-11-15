// SPDX-License-Identifier: GPL-3.0-or-later
//
// Permissions (PLT-R701-R741). Probes are cheap system calls made off the tap thread.

public import AppModel
public import Foundation
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
/// production), immediately on wake, session activation and menu open (PLT-R721). While a tap is installed
/// (`setTapInstalled(true)`) Accessibility alone is also checked every second, so a revoked grant removes the tap
/// within about a second even when macOS never disables it (PLT-R721, PLT-R730; the incident of 15/11/2026, decision
/// 0005). Remembers the identity digest of the last grant (key-value store) for `stale`.
///
/// Every probe call runs on `runner` (production: a serial queue of its own), never on the caller's thread and
/// never under the state lock: a TCC call that stalls (for example behind System Settings) holds only the runner,
/// so nothing the main thread calls here (`latest`, `requestCheck`, the setters) waits for it (PRD-R13, PLT-R730).
///
/// `onChange` runs for the first check after `start()` and then whenever the status changes, in check order,
/// one at a time and outside the check lock: it may call back into the monitor (`checkNow`, `setTapUnavailable`);
/// a status produced meanwhile is delivered after it returns. Logic: `PermissionMonitor+Checks.swift`.
public final class PermissionMonitor: Sendable {
    public static let notReadyInterval: TimeSpan = .seconds(2)
    public static let readyInterval: TimeSpan = .seconds(30)
    public static let onboardingInterval: TimeSpan = .seconds(1)
    /// PLT-R721: the live Accessibility check while a tap is installed (the one steady-state timer below 2 s,
    /// PLT-R803).
    public static let liveInterval: TimeSpan = .seconds(1)
    /// PLT-R711: fast polling stops by itself after 5 minutes.
    public static let onboardingLimit: TimeSpan = .seconds(300)
    /// `KeyValueStore` key of the last granted identity (a 52-bit hash of the designated requirement digest).
    public static let lastGrantedDigestKey = "PermissionLastGrantedIdentity"

    let probe: any PermissionProbe
    let store: any KeyValueStore
    let scheduler: any TimerScheduler
    let runner: any PermissionCheckRunner
    let delivery: OrderedDelivery<PermissionStatus>
    let state = Mutex(PermissionMonitorState())

    public init(
        probe: any PermissionProbe, store: any KeyValueStore, scheduler: any TimerScheduler,
        runner: any PermissionCheckRunner = InlinePermissionCheckRunner(),
        onChange: @escaping @Sendable (PermissionStatus) -> Void
    ) {
        self.probe = probe
        self.store = store
        self.scheduler = scheduler
        self.runner = runner
        self.delivery = OrderedDelivery(onChange)
    }

    /// The first check runs on the runner; its status reaches `onChange` like every other.
    public func start() { beginChecks() }
    public func stop() { endChecks() }
    /// Checks at once on the caller's thread and returns the newest status. For tests and callers that may wait;
    /// the main thread uses `requestCheck` (PLT-R730). When the check runs on main its status is delivered inside
    /// the call, and that delivery may already have replaced it (a `ready` whose tap failed, PLT-R702): the
    /// replacement is returned then, never the replaced status, so a caller that records or feeds the result agrees
    /// with what the receivers were told.
    public func checkNow() -> PermissionStatus {
        let status = check()
        return latest ?? status
    }
    /// Checks on the runner (PLT-R721: menu open, wake, session activation, a system tap disable) and then calls
    /// `completion` on the runner with the newest status (see `checkNow`). Returns at once.
    public func requestCheck(_ completion: (@Sendable (PermissionStatus) -> Void)? = nil) {
        runner.run { [self] in
            let status = check()
            completion?(latest ?? status)
        }
    }
    /// The status of the most recent check, already set while an older status is still being delivered. A receiver
    /// that forwards statuses compares the one in hand with this and drops it when a newer one is queued behind it,
    /// so a `ready` replaced during its own delivery (the tap it allowed failed, PLT-R702) never reaches the UI
    /// after its replacement (PRD-R40 screen 2). `nil` before the first check. Never waits for a probe call.
    public var latest: PermissionStatus? { state.withLock { $0.last } }
    /// Onboarding polls every 1 s for at most 5 minutes while visible (PLT-R711).
    public func setFastPolling(_ enabled: Bool) { updateFastPolling(enabled) }
    /// The lifecycle reports that the tap could not be created. With Accessibility granted and Input Monitoring
    /// missing (launch-time preflight and live check) this sets `listenEventRequired` (PLT-R702); the live check
    /// clears it when the user turns Input Monitoring on while the app runs (PLT-R731). The check runs on the runner.
    public func setTapUnavailable(_ unavailable: Bool) { updateTapUnavailable(unavailable) }
    /// The host installed (`true`) or removed (`false`) its tap: the 1 s live Accessibility check runs only while a
    /// tap is installed (PLT-R721).
    public func setTapInstalled(_ installed: Bool) { updateTapInstalled(installed) }
}

/// Where the permission monitor runs its probe calls (PLT-R730). Production: one serial queue of its own, so a TCC
/// call that stalls holds neither the main thread nor the shared utility queue. Tests: inline.
public protocol PermissionCheckRunner: Sendable {
    func run(_ work: @escaping @Sendable () -> Void)
}

/// Runs the work on the caller's thread (tests, and code that already runs off main).
public struct InlinePermissionCheckRunner: PermissionCheckRunner {
    public init() {}
    public func run(_ work: @escaping @Sendable () -> Void) { work() }
}

/// Runs the work on a serial dispatch queue (production).
public struct QueuePermissionCheckRunner: PermissionCheckRunner {
    public let queue: DispatchQueue
    public init(queue: DispatchQueue) { self.queue = queue }
    public func run(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}

extension PermissionProbe {
    /// A probe without a live check answers with the launch-time preflight. A wrapper forwards the live check
    /// explicitly (`RevocablePermissionProbe`), or this default would hide the wrapped probe's.
    public func canListenToEventsNow() -> Bool { canListenToEvents() }
}

/// "Đặt lại quyền" (PLT-R740): runs `/usr/bin/tccutil reset Accessibility <own bundle ID>` after the user
/// confirms. Never automatic, never without a bundle ID (PLT-R741), never with sudo.
public protocol PermissionResetting: Sendable {
    func resetAccessibility(bundleIdentifier: String) throws
}
