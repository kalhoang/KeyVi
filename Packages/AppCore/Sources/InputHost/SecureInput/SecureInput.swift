// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Secure Event Input (PLT-R395-R398C, P0-1). Only two pause signals exist: the OS secure-input state and an
// `AXSecureTextField` focus (PLT-R398A). No heuristics.

public import AppModel
public import Foundation
public import RealtimeSupport
import Synchronization

/// Production (`SystemSecureInputProbe`): `IsSecureEventInputEnabled()` (Carbon); holder via
/// `IORegistryEntryCreateCFProperty(IORegistryGetRootEntry(kIOMainPortDefault), "IOConsoleUsers", ...)`,
/// selecting the entry of the current console session and reading `kCGSSessionSecureInputPID`.
/// Never calls `EnableSecureEventInput` (PLT-R398).
public protocol SecureInputProbe: Sendable {
    func isSecureEventInputEnabled() -> Bool
    func secureInputHolderPID() -> Int32?
}

public struct SystemSecureInputProbe: SecureInputProbe {
    public init() {}
    public func isSecureEventInputEnabled() -> Bool { SecureInputSystem.isEnabled() }
    public func secureInputHolderPID() -> Int32? { SecureInputSystem.holderPID() }
}

/// Identity of a process for focus, holder naming and conflict detection.
public struct ProcessIdentity: Sendable, Hashable {
    public var pid: Int32
    /// Bundle ID, or SHA-256 of the executable path for bundle-less processes (PLT-R393).
    public var bundle: BundleKey
    public var bundleURL: URL?
    public var shortVersion: String?  // CFBundleShortVersionString
    public var buildVersion: String?  // CFBundleVersion (fingerprint cache key)
    public var appCategory: String?  // LSApplicationCategoryType
    public var localizedName: String?
    /// `proc_name`, used to recognise `loginwindow` without a bundle-ID literal (PLT-R396, PLT-R501).
    public var processName: String

    public init(
        pid: Int32, bundle: BundleKey, bundleURL: URL?, shortVersion: String?, buildVersion: String?,
        appCategory: String?, localizedName: String?, processName: String
    ) {
        self.pid = pid
        self.bundle = bundle
        self.bundleURL = bundleURL
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.appCategory = appCategory
        self.localizedName = localizedName
        self.processName = processName
    }
}

/// Production (`SystemProcessIdentityProvider`): `NSRunningApplication(processIdentifier:)`, `proc_pidpath`,
/// `proc_name`, `Bundle(url:)`.
public protocol ProcessIdentityProvider: Sendable {
    func identity(of pid: Int32) -> ProcessIdentity?
    func isAlive(_ pid: Int32) -> Bool  // kill(pid, 0) != ESRCH
    func runningApplications() -> [ProcessIdentity]
}

/// Polls every 2 s with 10 % leeway through the injected scheduler and on demand (menu open), publishes a
/// `SecureInputSnapshot` and names the likely holder with the data-driven hint key (PLT-R396, PLT-R397).
///
/// Episodes and generations (PLT-R398B): the generation changes on every OS transition. `keyEvidence(generation:)`
/// ENDS episode N: the tap stays resumed for generation N until the next poll, and the next poll that still sees
/// the OS flag on starts a new episode with a new generation even though no "off" was observed in between
/// (on -> off -> key -> on inside one poll interval must pause again, not stay resumed).
///
/// Snapshots are published in poll order, one at a time, outside the poll lock: `publish` may call back into
/// the monitor (`pollNow`, `keyEvidence`); a snapshot produced meanwhile is published after it returns.
/// Logic: `SecureInputMonitor+Polling.swift`.
public final class SecureInputMonitor: Sendable {
    public static let pollInterval: Duration = .seconds(2)
    /// PLT-R803: at least 10 % leeway on every timer.
    public static let pollLeeway: Duration = .milliseconds(200)

    let probe: any SecureInputProbe
    let processes: any ProcessIdentityProvider
    let hintKey: @Sendable (BundleKey) -> String?
    let scheduler: any TimerScheduler
    let delivery: OrderedDelivery<SecureInputSnapshot>
    let state = Mutex(SecureInputMonitorState())

    public init(
        probe: any SecureInputProbe, processes: any ProcessIdentityProvider,
        hintKey: @escaping @Sendable (BundleKey) -> String?, scheduler: any TimerScheduler,
        publish: @escaping @Sendable (SecureInputSnapshot) -> Void
    ) {
        self.probe = probe
        self.processes = processes
        self.hintKey = hintKey
        self.scheduler = scheduler
        self.delivery = OrderedDelivery(publish)
    }

    public func start() { beginPolling() }
    public func stop() { endPolling() }
    /// Synchronous poll (menu open, PLT-R395).
    public func pollNow() -> SecureInputSnapshot { poll() }
    /// The tap processed a key while paused for secure input (PLT-R398B): records the episode end; the state
    /// stays "resumed" for this generation until the next poll (see the type comment).
    public func keyEvidence(generation: UInt64) { recordKeyEvidence(generation: generation) }
}
