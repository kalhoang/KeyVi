// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The two seams the integration hooks drive (ADR 0502, "Integration hooks"; ADR 0313 testability seams): a tap
// factory that can time the current tap out the way macOS does (PLT-R330, QA-R11) and a permission probe whose
// Accessibility answer can be revoked and restored (PLT-R730, 7.3 re-grant). Only the app's INTEGRATION_HOOKS
// test build wraps its dependencies with them (App/Sources/IntegrationHooks); a release build links the types but
// never instantiates them, so the real trust check and the real tap stay untouched there.

internal import AppModel
internal import CoreFoundation
public import CoreGraphics
internal import RealtimeSupport
internal import Synchronization

/// The instrumented seams of one app run.
public struct IntegrationHookInstruments: Sendable {
    public let tapFactory: TimeoutSimulatingTapFactory
    public let permissions: RevocablePermissionProbe

    /// Wraps the tap factory and the permission probe of `dependencies`; everything else is unchanged.
    public static func instrument(_ dependencies: InputHostDependencies) -> (
        InputHostDependencies, IntegrationHookInstruments
    ) {
        let instruments = IntegrationHookInstruments(
            tapFactory: TimeoutSimulatingTapFactory(base: dependencies.tapFactory),
            permissions: RevocablePermissionProbe(base: dependencies.permissions))
        var instrumented = dependencies
        instrumented.tapFactory = instruments.tapFactory
        instrumented.permissions = instruments.permissions
        return (instrumented, instruments)
    }
}

/// `PermissionProbe` whose Accessibility and post-event answers read "denied" while revoked, as after the user
/// removes the app from Privacy & Security > Accessibility (posting needs the same grant). Input Monitoring, the
/// prompts and the signing identity come from the real probe.
public final class RevocablePermissionProbe: PermissionProbe, Sendable {
    private let base: any PermissionProbe
    private let revoked = Atomic<Bool>(false)

    public init(base: any PermissionProbe) { self.base = base }

    public var isRevoked: Bool { revoked.load(ordering: .acquiring) }
    public func setRevoked(_ value: Bool) { revoked.store(value, ordering: .releasing) }

    public func isAccessibilityTrusted() -> Bool { !isRevoked && base.isAccessibilityTrusted() }
    public func canPostEvents() -> Bool { !isRevoked && base.canPostEvents() }
    public func canListenToEvents() -> Bool { base.canListenToEvents() }
    public func promptForAccessibility() { base.promptForAccessibility() }
    public func requestListenEventAccess() -> Bool { base.requestListenEventAccess() }
    public func requestPostEventAccess() -> Bool { !isRevoked && base.requestPostEventAccess() }
    public func signingIdentityDigest() -> String? { base.signingIdentityDigest() }
}

/// `EventTapFactory` over the real (or fake) one that remembers the newest tap, so the `tapTimeout` hook can do
/// what macOS does when a callback overruns: disable the tap, then deliver `tapDisabledByTimeout` to its callback
/// on the tap thread. The pipeline's normal recovery runs from there (PLT-R330: re-enable, reset the composition,
/// replay held events, health event).
public final class TimeoutSimulatingTapFactory: EventTapFactory, Sendable {
    private let base: any EventTapFactory
    private let newest = Mutex<TimeoutSimulatingTapHandle?>(nil)

    public init(base: any EventTapFactory) { self.base = base }

    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        guard let handle = base.makeTap(mask: mask, callback: callback, userInfo: userInfo) else { return nil }
        let wrapped = TimeoutSimulatingTapHandle(base: handle, userInfo: UInt(bitPattern: userInfo))
        newest.withLock { $0 = wrapped }
        return wrapped
    }

    /// Times the newest tap out. False when there is no live tap (none created yet, or removed by fail-open).
    /// `delivered` runs on the tap thread after the callback returned (tests use it as a barrier).
    @discardableResult
    public func simulateTimeout(delivered: (@Sendable () -> Void)? = nil) -> Bool {
        guard let handle = newest.withLock({ $0 }) else { return false }
        return handle.simulateTimeout(delivered: delivered)
    }
}

/// The wrapped handle: forwards everything and records the tap thread's run loop at `install`.
final class TimeoutSimulatingTapHandle: EventTapHandle, Sendable {
    /// CF run loops are thread-safe to perform blocks on and wake from any thread.
    private struct RunLoopBox: @unchecked Sendable { let runLoop: CFRunLoop }

    private let base: any EventTapHandle
    private let userInfo: UInt
    private let runLoop = Mutex<RunLoopBox?>(nil)
    private let invalidated = Atomic<Bool>(false)

    init(base: any EventTapHandle, userInfo: UInt) {
        self.base = base
        self.userInfo = userInfo
    }

    func install(on runLoop: CFRunLoop) {
        self.runLoop.withLock { $0 = RunLoopBox(runLoop: runLoop) }
        base.install(on: runLoop)
    }

    func setEnabled(_ enabled: Bool) { base.setEnabled(enabled) }
    var isEnabled: Bool { base.isEnabled }

    func invalidate() {
        invalidated.store(true, ordering: .releasing)
        runLoop.withLock { $0 = nil }
        base.invalidate()
    }

    /// The callback's `userInfo` points at the tap thread's state, which lives as long as that thread runs its
    /// run loop; a block performed on the run loop therefore runs only while the state exists.
    func simulateTimeout(delivered: (@Sendable () -> Void)?) -> Bool {
        guard !invalidated.load(ordering: .acquiring), userInfo != 0, let box = runLoop.withLock({ $0 }) else {
            return false
        }
        base.setEnabled(false)
        let userInfo = self.userInfo
        CFRunLoopPerformBlock(box.runLoop, CFRunLoopMode.defaultMode.rawValue) {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: userInfo) else { return }
            let event = RawKeyEvent(
                kind: .tapDisabledByTimeout, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false,
                keyboardType: 0, unicode: .empty, userData: 0, receivedAt: MachClock().now())
            _ = TapCallbackBridge.deliver(event, userInfo: pointer)
            delivered?()
        }
        CFRunLoopWakeUp(box.runLoop)
        return true
    }
}
