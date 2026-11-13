// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The main thread shows what the tap does (PRD-R10, PRD-R11): when the focus tracker publishes a new snapshot
// on the ax thread, the icon and the menu must follow. The tracker has no publication callback, so the host
// wraps its AX provider: after the tracker's handler queued its resolution on the ax thread, the decorator queues
// the main-thread wake-up behind it (run-loop blocks run in order), so the main thread reads the snapshot the
// notification produced. Workstream W2-A.

public import Injection
public import RealtimeSupport

/// Decorator around the real `AXProvider`; every call is forwarded unchanged.
public struct FocusChangeSignalingAXProvider: AXProvider {
    private let base: any AXProvider
    private let thread: RunLoopThread
    private let afterNotification: @Sendable () -> Void

    /// `thread` is the ax thread the tracker runs on; `afterNotification` runs there after the block the
    /// tracker queued for the notification. It must not block (production: `WakeSignal.signal()`).
    public init(base: any AXProvider, thread: RunLoopThread, afterNotification: @escaping @Sendable () -> Void) {
        self.base = base
        self.thread = thread
        self.afterNotification = afterNotification
    }

    public func focusedApplication() -> AXCallResult<Int32?> { base.focusedApplication() }

    public func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?> { base.focusedElement(pid: pid) }

    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        base.attributes(of: element, request: request)
    }

    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? {
        let afterNotification = self.afterNotification
        let thread = self.thread
        return base.observe(pid: pid, notifications: notifications) { kind in
            handler(kind)
            thread.perform(afterNotification)
        }
    }

    public func enableManualAccessibility(pid: Int32) -> Bool { base.enableManualAccessibility(pid: pid) }
}
