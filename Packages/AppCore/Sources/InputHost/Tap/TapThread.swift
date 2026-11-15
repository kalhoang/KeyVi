// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `tap` thread (PLT-R203, PLT-R301-R303): one active session-level, head-insert event tap whose run-loop
// source is the only source on its run loop. Workstream W1-F2.

public import CoreFoundation
public import CoreGraphics
public import RealtimeSupport

/// Event mask of PLT-R301 (`keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `rightMouseDown`,
/// `otherMouseDown`) plus `scrollWheel`, which is on by default because PRD-R14 (MUST) cancels the Control+Shift
/// toggle tap on scroll; PLT-R301 allows `scrollWheel` only for that purpose. For a scroll event the callback
/// does nothing except `HotkeyRecognizer.handle(.scroll)` ("chord cancelled") and returns the event unchanged.
public struct TapEventMask: Sendable, Hashable {
    public static let standard = TapEventMask(includeScrollWheel: true)

    public var includeScrollWheel: Bool
    public init(includeScrollWheel: Bool = true) { self.includeScrollWheel = includeScrollWheel }

    public var cgMask: CGEventMask {
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if includeScrollWheel { types.append(.scrollWheel) }
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }
}

/// The tap's mach port and run-loop source behind a protocol, so the tap thread and the watchdogs are testable
/// without the WindowServer (docs/decisions/0313-testability-seams.md). Production wraps the `CFMachPort`
/// returned by `CGEvent.tapCreate`; `FakeEventTapFactory` (TestSupport) returns a pure Swift handle.
public protocol EventTapHandle: AnyObject, Sendable {
    /// Adds the tap's run-loop source to `runLoop`, the tap thread's own run loop (PLT-R303).
    func install(on runLoop: CFRunLoop)
    /// `CGEvent.tapEnable(tap:enable:)`; any thread (watchdog and fail-open use it, PLT-R306, PLT-R730).
    func setEnabled(_ enabled: Bool)
    /// `CGEvent.tapIsEnabled(tap:)` (PLT-R331); any thread.
    var isEnabled: Bool { get }
    /// Removes the source from its run loop and invalidates the port (PLT-R730).
    func invalidate()
}

/// Creates the event tap, on the tap thread. Production: `CGEvent.tapCreate(tap: .cgSessionEventTap,
/// place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask.cgMask, callback: callback,
/// userInfo: userInfo)`. Returns nil when the OS refuses (no permission): the host enters
/// `failOpen(tapUnavailable)` (PLT-R332).
public protocol EventTapFactory: Sendable {
    func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
}

/// The real tap (PLT-R301): session level, head insert, active (default) option. Never used by tests on a
/// developer Mac; they use `FakeEventTapFactory` (ADR 0313). Verified on the self-hosted runner (W2-E2).
public struct CGEventTapFactory: EventTapFactory {
    public init() {}
    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask.cgMask, callback: callback, userInfo: userInfo)
        else { return nil }
        return MachPortEventTapHandle(port: port)
    }
}

/// Per-event handler created ON the tap thread and used only there (PLT-R303). `KeyPipeline` conforms.
/// Deliberately not `Sendable`: Swift 6 cannot express "owned by this run-loop thread", so `TapThread` builds
/// the handler inside its thread entry from a `@Sendable` factory and never lets it escape that thread. This is
/// one of the two audited concurrency escape hatches (the other is `ThreadConfined`, ARCHITECTURE.md section 3).
/// `SendableMetatype`: the conformance is used on the tap thread, so it must not be isolated to an actor.
public protocol TapEventHandler: AnyObject, SendableMetatype {
    func handle(_ event: RawKeyEvent) -> TapVerdict
}

/// What the watchdog and the lifecycle owner may do with a running tap, from any thread.
public protocol TapControl: AnyObject, Sendable {
    func setEnabled(_ enabled: Bool)
    var isEnabled: Bool { get }
    /// False once the tap thread's run loop has exited (after `stop()`), true while it runs.
    var isRunning: Bool { get }
    func stop()
}

/// Owns the tap thread and the tap handle. The thread entry calls `makeHandler()` (so the non-Sendable handler
/// and the `KeyPipeline` inside it are created on the tap thread), creates the tap through the factory with a
/// C callback whose `userInfo` points at that thread's state, installs the source and runs the CFRunLoop. The
/// callback converts the `CGEvent` into a `RawKeyEvent`, calls `handler.handle`, and returns
/// `Unmanaged.passUnretained(event)` or nil. Generic over the handler, so the per-event call is static: the C
/// callback (which cannot capture generic parameters) reaches the specialised thread state through one class
/// method dispatch, without allocation or locking (PLT-R304, `TapCallbackBridge`).
///
/// A `TapThread` is single-use: after `stop()` (or a failed `start()`) the host creates a fresh one, and only
/// once `isRunning` is false (ADR 0309). Releasing the last reference stops it.
public final class TapThread<Handler: TapEventHandler>: TapControl, Sendable {
    private let runtime = TapThreadRuntime()
    private let factory: any EventTapFactory
    private let mask: TapEventMask
    private let makeHandler: @Sendable () -> Handler
    private let creationTimeout: TimeSpan

    public init(
        factory: any EventTapFactory, mask: TapEventMask = .standard, creationTimeout: TimeSpan? = nil,
        makeHandler: @escaping @Sendable () -> Handler
    ) {
        self.factory = factory
        self.mask = mask
        self.creationTimeout = creationTimeout ?? TapThreadRuntime.creationTimeout
        self.makeHandler = makeHandler
    }

    deinit { runtime.stop() }

    /// Creates the tap on a new thread (QoS user-interactive) and runs its CFRunLoop. Returns once creation
    /// succeeded or failed; false if the factory returned nil (the thread then exits) or did not answer within the
    /// creation timeout (a tap it returns later is invalidated, never enabled). True without a second tap when
    /// already running (PLT-R302); false after `stop()`.
    public func start() -> Bool {
        let factory = self.factory
        let mask = self.mask
        let makeHandler = self.makeHandler
        return runtime.start(timeout: creationTimeout) {
            // Tap thread (PLT-R303): the handler and the tap are created here and never leave this thread.
            let target = TapCallbackContext(handler: makeHandler())
            let userInfo = Unmanaged.passUnretained(target).toOpaque()
            guard let handle = factory.makeTap(mask: mask, callback: TapCallbackBridge.callback, userInfo: userInfo)
            else { return nil }
            return TapThreadRuntime.Session(handle: handle, target: target)
        }
    }

    public func setEnabled(_ enabled: Bool) { runtime.setEnabled(enabled) }
    public var isEnabled: Bool { runtime.isEnabled }
    public var isRunning: Bool { runtime.isRunning }

    /// Disables, invalidates the handle and stops the run loop so the thread exits (PLT-R730). Never called
    /// while the watchdog reports a callback that has not returned (ADR 0309). Does not wait for the exit.
    public func stop() { runtime.stop() }

    /// Waits until the thread has left its run loop (or never started). False on timeout. For the owner that
    /// recreates the tap after `stop()` (ADR 0309) and for tests; never called on the tap thread.
    public func waitUntilExited(timeout: TimeSpan) -> Bool { runtime.waitUntilExited(timeout: timeout) }
}
