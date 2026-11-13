// SPDX-License-Identifier: LicenseRef-App-Pending

/// Bounded lock-free single-producer single-consumer queue (PLT-R304 "pushing onto a lock-free
/// single-producer queue"). Storage is allocated once; push and pop never allocate or block.
///
/// Discipline (checked in debug builds by the owners, not by this type): exactly one producer thread calls
/// `push`, exactly one consumer thread calls `pop`. Elements are destroyed on the consumer thread.
public final class SPSCRing<Element: Sendable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element?>
    private let head = Atomic<Int>(0)  // next slot to pop, written by the consumer
    private let tail = Atomic<Int>(0)  // next slot to push, written by the producer

    /// `capacity` MUST be a power of two.
    public init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: nil, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer only. Returns false when full (the caller treats that as a liveness flush, PLT-R314).
    @inline(__always)
    public func push(_ element: consuming Element) -> Bool {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)
        guard currentTail &- currentHead < capacity else { return false }
        (storage + (currentTail & mask)).pointee = element
        tail.store(currentTail &+ 1, ordering: .releasing)
        return true
    }

    /// Consumer only.
    @inline(__always)
    public func pop() -> Element? {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        guard currentHead != currentTail else { return nil }
        let slot = storage + (currentHead & mask)
        let element = slot.move()
        slot.initialize(to: nil)
        head.store(currentHead &+ 1, ordering: .releasing)
        return element
    }

    /// Approximate from any thread; exact from the producer or the consumer.
    public var count: Int { tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring) }
}
