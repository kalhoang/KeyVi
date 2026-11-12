// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Snapshot publication (PLT-R304, PLT-R388, docs/decisions/0303-snapshot-publication.md).
//
// Writers (main, ax, utility) publish immutable values; the tap thread reads the current value with ONE
// atomic load and no retain, lock or allocation. Memory safety for the tap reader comes from quiescent-state
// based reclamation (QSBR) with a single reader: the tap brackets every callback with `ReaderEpoch.enter()`
// and `exit()`, and a writer frees a replaced box only after the epoch shows that the tap has left any read
// section that could have loaded it. Boxes are therefore always released on a writer thread, never on the tap.
//
// Readers other than the tap use `load()`, which takes a short writer-side lock and returns a strong copy.

internal import Synchronization

/// Read-section counter for the single tap reader. Even = outside a callback, odd = inside.
public final class ReaderEpoch: Sendable {
    private let counter = Atomic<UInt64>(0)

    public init() {}

    /// First statement of the tap callback (an "atomic counter update", allowed by PLT-R304).
    @inline(__always)
    public func enter() { counter.wrappingAdd(1, ordering: .sequentiallyConsistent) }

    /// Last statement of the tap callback, on every return path.
    @inline(__always)
    public func exit() { counter.wrappingAdd(1, ordering: .sequentiallyConsistent) }

    var value: UInt64 { counter.load(ordering: .sequentiallyConsistent) }
}

/// Immutable value published through one atomic reference (Appendix B "Snapshot").
public final class SnapshotCell<Value: Sendable>: Sendable {
    private final class Box: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct WriterState: @unchecked Sendable {
        // Unmanaged boxes retired by `publish`, with the reader epoch observed right after the exchange.
        var retired: [(box: Unmanaged<Box>, epoch: UInt64)] = []
        var latest: Value
    }

    private let current: Atomic<Unmanaged<Box>>
    private let writer: Mutex<WriterState>
    private let epoch: ReaderEpoch

    public init(_ initial: Value, epoch: ReaderEpoch) {
        self.epoch = epoch
        current = Atomic(Unmanaged.passRetained(Box(initial)))
        writer = Mutex(WriterState(latest: initial))
    }

    deinit {
        current.load(ordering: .sequentiallyConsistent).release()
        writer.withLock { state in
            for entry in state.retired { entry.box.release() }
            state.retired.removeAll()
        }
    }

    /// Tap thread only, between `ReaderEpoch.enter()` and `exit()`. One atomic load; the value is borrowed
    /// for the duration of `body` and MUST NOT escape it.
    @inline(__always)
    public func read<R>(_ body: (Value) -> R) -> R {
        current.load(ordering: .sequentiallyConsistent)._withUnsafeGuaranteedRef { body($0.value) }
    }

    /// Any thread except the tap. Returns a strong copy; may wait for a concurrent `publish` (O(1) work).
    public func load() -> Value {
        writer.withLock { $0.latest }
    }

    /// Main, ax or utility thread. Never called on the tap thread.
    public func publish(_ value: Value) {
        let fresh = Unmanaged.passRetained(Box(value))
        writer.withLock { state in
            let old = current.exchange(fresh, ordering: .sequentiallyConsistent)
            state.retired.append((old, epoch.value))
            state.latest = value
            reclaim(&state)
        }
    }

    /// Frees boxes the tap can no longer reference. Called by `publish` and by the utility watchdog.
    public func reclaim() {
        writer.withLock { reclaim(&$0) }
    }

    private func reclaim(_ state: inout WriterState) {
        let now = epoch.value
        state.retired.removeAll { entry in
            // Even epoch at retire time: the tap was outside a callback, later callbacks load the new box.
            // Odd epoch: the callback that may hold the old box has ended once the counter moved on.
            let safe = entry.epoch & 1 == 0 || now != entry.epoch
            if safe { entry.box.release() }
            return safe
        }
    }
}
