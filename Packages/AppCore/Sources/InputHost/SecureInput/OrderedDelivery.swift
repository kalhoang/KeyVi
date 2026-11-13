// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-order, non-nested delivery of monitor results outside the monitor's state lock (PLT-R395, PLT-R721).
// Monitors enqueue under their state lock (so the queue order is the computation order) and drain after
// releasing it. Exactly one thread delivers at a time; a value enqueued while a delivery runs (from another
// thread or from inside the callback itself) is delivered by that thread right after the current callback
// returns. A callback may therefore call back into the monitor without deadlocking or nesting.

import RealtimeSupport

final class OrderedDelivery<Value: Sendable>: Sendable {
    private struct State {
        var pending: [Value] = []
        var delivering = false
    }

    private let state = Mutex(State())
    private let deliver: @Sendable (Value) -> Void

    init(_ deliver: @escaping @Sendable (Value) -> Void) { self.deliver = deliver }

    func enqueue(_ value: Value) { state.withLock { $0.pending.append(value) } }

    /// Delivers everything pending unless another drain is already running. Never call with a lock held that
    /// the callback might take.
    func drain() {
        let owner = state.withLock { state -> Bool in
            guard !state.delivering, !state.pending.isEmpty else { return false }
            state.delivering = true
            return true
        }
        guard owner else { return }
        while let next = takeNext() { deliver(next) }
    }

    private func takeNext() -> Value? {
        state.withLock { state in
            guard !state.pending.isEmpty else {
                state.delivering = false
                return nil
            }
            return state.pending.removeFirst()
        }
    }
}
