// SPDX-License-Identifier: GPL-3.0-or-later

public import Dispatch

/// Wake-up from the tap thread to a dispatch queue without blocking, locking or allocating: a
/// `DispatchSourceUserDataAdd` merge coalesces signals and runs `handler` once on `queue`. Used for tap ->
/// main (outbox), tap -> utility (watchdog arming) and tap -> ax (revalidation, via a hop) notifications.
public final class WakeSignal: Sendable {
    private let source: any DispatchSourceUserDataAdd

    public init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    /// Safe on the tap thread.
    @inline(__always)
    public func signal() { source.add(data: 1) }

    public func cancel() { source.cancel() }
}

/// Wake-up for the `inject` thread's condition-driven loop (PLT-R203). `signal()` never blocks the caller;
/// only the worker waits, with an absolute deadline (PLT-R409).
public final class WorkerSignal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    /// Safe on the tap thread.
    @inline(__always)
    public func signal() { semaphore.signal() }

    /// Worker only. Returns false when the deadline passed without a signal.
    public func wait(until deadline: MonotonicInstant?) -> Bool {
        guard let deadline else {
            semaphore.wait()
            return true
        }
        return semaphore.wait(timeout: DispatchTime(uptimeNanoseconds: deadline.nanoseconds)) == .success
    }
}
