// SPDX-License-Identifier: LicenseRef-App-Pending
//
// How background callbacks (permission and secure-input monitors, timers on the utility queue, the ax thread)
// reach the main-actor controller. Production hops through the main dispatch queue; tests run the blocks in
// order on demand, so no test waits for real time (ADR 0313). Workstream W2-A.

internal import Foundation
internal import RealtimeSupport

/// Runs main-actor work posted from any thread, in posting order.
public protocol MainThreadHop: Sendable {
    func hop(_ body: @escaping @MainActor @Sendable () -> Void)
}

/// Production: `DispatchQueue.main` (the main actor's executor). A caller already on the main thread runs the
/// block at once, so timers driven on main and synchronous monitor callbacks keep their order.
public struct DispatchMainHop: MainThreadHop {
    public init() {}

    public func hop(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}

/// Tests: queues blocks until `drain()` runs them on the main actor.
public final class ManualMainHop: MainThreadHop {
    private let blocks = Mutex<[@MainActor @Sendable () -> Void]>([])

    public init() {}

    public func hop(_ body: @escaping @MainActor @Sendable () -> Void) {
        blocks.withLock { $0.append(body) }
    }

    /// Runs queued blocks, including blocks they queue, until none is left. Returns how many ran.
    @MainActor
    @discardableResult
    public func drain() -> Int {
        var count = 0
        while let next = blocks.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            next()
            count += 1
        }
        return count
    }

    public var pendingCount: Int { blocks.withLock { $0.count } }
}
