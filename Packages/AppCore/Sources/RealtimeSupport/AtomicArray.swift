// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Fixed-size array of atomic UInt64 slots (histogram buckets, the worker outcome board). `Atomic` is
// non-copyable, so it cannot live in a Swift `Array`; storage is allocated once and never resized, so every
// operation after `init` is lock-free and allocation-free (PLT-R304).

internal import Synchronization

public final class AtomicUInt64Array: @unchecked Sendable {
    // @unchecked: the pointer is written only at init and deinit; every slot is an `Atomic`.
    public let count: Int
    private let slots: UnsafeMutablePointer<Atomic<UInt64>>

    public init(count: Int, initialValue: UInt64 = 0) {
        precondition(count > 0)
        self.count = count
        slots = .allocate(capacity: count)
        for index in 0..<count { (slots + index).initialize(to: Atomic(initialValue)) }
    }

    deinit {
        slots.deinitialize(count: count)
        slots.deallocate()
    }

    @inline(__always)
    public func load(_ index: Int) -> UInt64 {
        precondition(index >= 0 && index < count)
        return slots[index].load(ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func store(_ value: UInt64, at index: Int) {
        precondition(index >= 0 && index < count)
        slots[index].store(value, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func increment(_ index: Int, by amount: UInt64 = 1) {
        precondition(index >= 0 && index < count)
        slots[index].wrappingAdd(amount, ordering: .relaxed)
    }

    /// Copies every slot (not atomic as a whole; each slot is read atomically).
    public func snapshot() -> [UInt64] { (0..<count).map(load) }
}
