// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixed-size array of atomic UInt64 slots (histogram buckets, the worker outcome board). The words are allocated
// once and never resized, and every slot is accessed through `UnsafeAtomic`, so every operation after `init` is
// lock-free and allocation-free (PLT-R304).

public final class AtomicUInt64Array: @unchecked Sendable {
    // @unchecked: the pointer is written only at init and deinit; every slot is accessed atomically.
    public let count: Int
    private let words: UnsafeMutablePointer<UInt64>

    public init(count: Int, initialValue: UInt64 = 0) {
        precondition(count > 0)
        self.count = count
        words = .allocate(capacity: count)
        words.initialize(repeating: initialValue, count: count)
    }

    deinit {
        words.deinitialize(count: count)
        words.deallocate()
    }

    @inline(__always)
    private func slot(_ index: Int) -> UnsafeAtomic<UInt64> {
        precondition(index >= 0 && index < count)
        return UnsafeAtomic(at: words + index)
    }

    @inline(__always)
    public func load(_ index: Int) -> UInt64 {
        slot(index).load(ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func store(_ value: UInt64, at index: Int) {
        slot(index).store(value, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func increment(_ index: Int, by amount: UInt64 = 1) {
        slot(index).wrappingAdd(amount, ordering: .relaxed)
    }

    /// Copies every slot (not atomic as a whole; each slot is read atomically).
    public func snapshot() -> [UInt64] { (0..<count).map(load) }
}
