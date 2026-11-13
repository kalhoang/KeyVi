// SPDX-License-Identifier: GPL-3.0-or-later
//
// A read that may block on another process (lazily provided pasteboard data waits on its owner), bounded by a
// deadline: PLT-R461 step 1 ("if any item cannot be read within 100 ms ... abort"), PLT-R462 (the worker waits
// on its own condition with a timeout), PRD-R44 (the keyboard is never left unusable: the tap holds keys while a
// job runs, PLT-R311, so a job must not block for long).

internal import Dispatch
internal import RealtimeSupport

/// Runs one read at a time on a private serial queue; the caller (the `inject` thread) waits at most the
/// timeout. A read that overruns keeps running on the queue and the caller moves on; until it ends, every
/// other read answers nil at once, so no second call ever touches the resource concurrently.
final class BoundedRead: Sendable {
    private final class Slot<Value: Sendable>: Sendable {
        let value = Mutex<Value?>(nil)
    }

    private final class Busy: Sendable {
        let flag = Atomic<Bool>(false)
    }

    private let queue: DispatchQueue
    private let busy = Busy()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// A read is still running (possibly one the caller gave up on).
    var isBusy: Bool { busy.flag.load(ordering: .sequentiallyConsistent) }

    /// The value, or nil when `body` did not finish within `timeout` or an earlier read is still running.
    func run<Value: Sendable>(timeout: TimeSpan, _ body: @escaping @Sendable () -> Value) -> Value? {
        guard busy.flag.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        else { return nil }
        let slot = Slot<Value>()
        let done = DispatchSemaphore(value: 0)
        let busy = self.busy
        queue.async {
            let value = body()
            slot.value.withLock { $0 = value }
            busy.flag.store(false, ordering: .sequentiallyConsistent)
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.dispatchInterval(timeout)) == .success else { return nil }
        return slot.value.withLock { $0 }
    }

    static func dispatchInterval(_ duration: TimeSpan) -> DispatchTimeInterval { duration.dispatchInterval }
}
