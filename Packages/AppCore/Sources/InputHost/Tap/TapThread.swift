// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The `tap` thread (PLT-R203, PLT-R301-R303): one active session-level, head-insert event tap whose run-loop
// source is the only source on its run loop.

internal import AppModel
public import CoreGraphics
public import Dispatch

/// Event mask of PLT-R301 (`keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `rightMouseDown`,
/// `otherMouseDown`, optionally `scrollWheel`).
public struct TapEventMask: Sendable, Hashable {
    public var includeScrollWheel: Bool
    public init(includeScrollWheel: Bool) { self.includeScrollWheel = includeScrollWheel }
    public var cgMask: CGEventMask { unimplemented() }
}

/// Creates the event tap. Production: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
/// options: .defaultTap, eventsOfInterest: mask.cgMask, callback: callback, userInfo: userInfo)`.
/// Returns nil when the OS refuses (no permission): the host enters `failOpen(tapUnavailable)` (PLT-R332).
public protocol EventTapFactory: Sendable {
    func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> CFMachPort?
}

public struct CGEventTapFactory: EventTapFactory {
    public init() {}
    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> CFMachPort?
    { unimplemented() }
}

/// Owns the tap thread and the tap's mach port. The C callback converts the `CGEvent` into a `RawKeyEvent`,
/// calls `KeyPipeline.handle`, and returns `Unmanaged.passUnretained(event)` or nil.
public final class TapThread: Sendable {
    /// `handler` is called on the tap thread only.
    public init(factory: any EventTapFactory, mask: TapEventMask, handler: @escaping @Sendable (RawKeyEvent) -> TapVerdict) {
        unimplemented()
    }

    /// Creates the tap on a new thread (QoS user-interactive) and runs its CFRunLoop. False if creation failed.
    public func start() -> Bool { unimplemented() }
    /// `CGEventTapEnable`; callable from any thread (watchdog and fail-open use it, PLT-R306, PLT-R730).
    public func setEnabled(_ enabled: Bool) { unimplemented() }
    /// `CGEventTapIsEnabled` (PLT-R331).
    public var isEnabled: Bool { unimplemented() }
    /// Disables, removes the source, invalidates the port and lets the thread exit (PLT-R730).
    public func stop() { unimplemented() }
}

/// PLT-R306 and PLT-R331 on the utility queue. The 250 ms callback check runs only while keys are flowing
/// (armed by the tap's activity `WakeSignal`, disarmed after 2 s idle), so idle wakeups stay at zero
/// (PLT-R803); the tap-enabled check runs every 5 s with leeway and on wake, session activation and
/// permission change.
public final class TapWatchdog: Sendable {
    public init(
        tap: TapThread, callbacks: CallbackWatchdog, queue: DispatchQueue, onTrip: @escaping @Sendable (TapTrip) -> Void
    ) { unimplemented() }

    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    /// Called on wake, session activation, permission change (PLT-R331).
    public func checkNow() { unimplemented() }

    public enum TapTrip: Sendable, Hashable {
        case callbackOverLimit(microseconds: UInt64)  // -> failOpen(watchdog), retry after 2 s
        case unexpectedlyDisabled  // -> PLT-R330 procedure
    }
}
