// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lock-free atomics with explicit memory orderings (PLT-R304, PLT-R388) for macOS 12 and later
// (docs/decisions/0315-minimum-macos-12.md). The API mirrors the `Synchronization` module's `Atomic`, which
// needs macOS 15, so call sites read the same: `Atomic<Int>(0)`, `load(ordering: .acquiring)`,
// `wrappingAdd(1, ordering: .relaxed)`, `compareExchange(expected:desired:ordering:)`.
//
// Differences from `Synchronization.Atomic`, all deliberate:
// - `Atomic` is a copyable handle to one word allocated at `init` (copies share the word); after `init` no
//   operation allocates, locks or blocks.
// - `UnsafeAtomic` applies the same operations to a word someone else owns (a raw buffer, a C global).
// - Only the operations the code base uses exist; add more here rather than reaching for another module.

public import CRealtimeSupport

#if !(arch(arm64) || arch(x86_64))
#error("RealtimeSupport atomics assume a 64-bit Apple platform (PLT-R105: arm64 and x86_64)")
#endif

// MARK: - Orderings

/// Memory ordering of an atomic load.
public struct AtomicLoadOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// Later reads and writes stay after this load; pairs with a releasing store.
    @inlinable public static var acquiring: Self { Self(rawValue: 2) }
    /// Acquiring, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

/// Memory ordering of an atomic store.
public struct AtomicStoreOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// Earlier reads and writes stay before this store; pairs with an acquiring load.
    @inlinable public static var releasing: Self { Self(rawValue: 3) }
    /// Releasing, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

/// Memory ordering of an atomic read-modify-write operation.
public struct AtomicUpdateOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// The read half acquires.
    @inlinable public static var acquiring: Self { Self(rawValue: 2) }
    /// The write half releases.
    @inlinable public static var releasing: Self { Self(rawValue: 3) }
    /// Both halves: acquiring read, releasing write.
    @inlinable public static var acquiringAndReleasing: Self { Self(rawValue: 4) }
    /// Acquiring and releasing, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

// MARK: - Storage words

/// An unsigned word the C layer operates on atomically (8, 32 or 64 bits).
public protocol AtomicStorageWord: FixedWidthInteger, UnsignedInteger, Sendable {
    static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt)
    static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    /// Returns whether the exchange happened and the value found (equal to `expected` when it happened).
    static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self)
    /// Wrapping add; returns the previous value.
    static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    /// Wrapping subtract; returns the previous value.
    static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
}

extension UInt8: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u8(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u8(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u8(address, value, ordering)
    }
}

extension UInt32: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u32(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u32(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u32(address, value, ordering)
    }
}

extension UInt64: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u64(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u64(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u64(address, value, ordering)
    }
}

// MARK: - Representable values

/// A value that round-trips through one atomic storage word.
public protocol AtomicRepresentable {
    associatedtype AtomicRepresentation: AtomicStorageWord
    static func encodeAtomicRepresentation(_ value: Self) -> AtomicRepresentation
    static func decodeAtomicRepresentation(_ representation: AtomicRepresentation) -> Self
}

/// An integer stored as its own bit pattern in a word of the same width, so wrapping arithmetic on the word is
/// wrapping arithmetic on the value.
public protocol AtomicInteger: AtomicRepresentable, FixedWidthInteger {}

extension AtomicInteger {
    @inlinable public static func encodeAtomicRepresentation(_ value: Self) -> AtomicRepresentation {
        AtomicRepresentation(truncatingIfNeeded: value)
    }
    @inlinable public static func decodeAtomicRepresentation(_ representation: AtomicRepresentation) -> Self {
        Self(truncatingIfNeeded: representation)
    }
}

extension UInt8: AtomicInteger { public typealias AtomicRepresentation = UInt8 }
extension Int8: AtomicInteger { public typealias AtomicRepresentation = UInt8 }
extension UInt32: AtomicInteger { public typealias AtomicRepresentation = UInt32 }
extension Int32: AtomicInteger { public typealias AtomicRepresentation = UInt32 }
extension UInt64: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension Int64: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension UInt: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension Int: AtomicInteger { public typealias AtomicRepresentation = UInt64 }

extension Bool: AtomicRepresentable {
    public typealias AtomicRepresentation = UInt8
    @inlinable public static func encodeAtomicRepresentation(_ value: Bool) -> UInt8 { value ? 1 : 0 }
    @inlinable public static func decodeAtomicRepresentation(_ representation: UInt8) -> Bool { representation != 0 }
}

extension Unmanaged: AtomicRepresentable {
    public typealias AtomicRepresentation = UInt64
    @inlinable public static func encodeAtomicRepresentation(_ value: Unmanaged<Instance>) -> UInt64 {
        UInt64(UInt(bitPattern: value.toOpaque()))
    }
    @inlinable public static func decodeAtomicRepresentation(_ representation: UInt64) -> Unmanaged<Instance> {
        // Only ever decodes words written by `encodeAtomicRepresentation`, which are never null.
        Unmanaged.fromOpaque(UnsafeRawPointer(bitPattern: UInt(representation))!)
    }
}

// MARK: - Operations on a word

/// Atomic operations on a word owned elsewhere (raw buffers, C globals). The caller keeps the memory alive,
/// aligned and accessed only atomically for as long as any `UnsafeAtomic` refers to it.
public struct UnsafeAtomic<Value: AtomicRepresentable>: @unchecked Sendable {
    // @unchecked: a plain address; atomicity of every access is the point of the type.
    public let address: UnsafeMutablePointer<Value.AtomicRepresentation>

    @inlinable public init(at address: UnsafeMutablePointer<Value.AtomicRepresentation>) { self.address = address }

    @inlinable
    public func load(ordering: AtomicLoadOrdering) -> Value {
        Value.decodeAtomicRepresentation(.atomicLoad(address, ordering: ordering.rawValue))
    }

    @inlinable
    public func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        Value.AtomicRepresentation.atomicStore(
            Value.encodeAtomicRepresentation(desired), to: address, ordering: ordering.rawValue)
    }

    /// Stores `desired` and returns the previous value.
    @inlinable @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        Value.decodeAtomicRepresentation(
            .atomicExchange(Value.encodeAtomicRepresentation(desired), at: address, ordering: ordering.rawValue))
    }

    /// Stores `desired` if the current value is `expected` (strong: no spurious failure). The failure ordering
    /// is the success ordering without its releasing half.
    @inlinable
    public func compareExchange(expected: Value, desired: Value, ordering: AtomicUpdateOrdering)
        -> (exchanged: Bool, original: Value)
    {
        let result = Value.AtomicRepresentation.atomicCompareExchange(
            expected: Value.encodeAtomicRepresentation(expected), desired: Value.encodeAtomicRepresentation(desired),
            at: address, ordering: ordering.rawValue)
        return (result.exchanged, Value.decodeAtomicRepresentation(result.original))
    }
}

extension UnsafeAtomic where Value: AtomicInteger {
    @inlinable @discardableResult
    public func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let old = Value.decodeAtomicRepresentation(
            .atomicFetchAdd(Value.encodeAtomicRepresentation(operand), at: address, ordering: ordering.rawValue))
        return (old, old &+ operand)
    }

    @inlinable @discardableResult
    public func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering)
        -> (oldValue: Value, newValue: Value)
    {
        let old = Value.decodeAtomicRepresentation(
            .atomicFetchSubtract(Value.encodeAtomicRepresentation(operand), at: address, ordering: ordering.rawValue))
        return (old, old &- operand)
    }

    /// Adds `operand` and traps if the result overflowed (the word keeps the wrapped value).
    @inlinable @discardableResult
    public func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let result = wrappingAdd(operand, ordering: ordering)
        precondition(!result.oldValue.addingReportingOverflow(operand).overflow, "atomic add overflowed")
        return result
    }

    /// Subtracts `operand` and traps if the result overflowed (the word keeps the wrapped value).
    @inlinable @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let result = wrappingSubtract(operand, ordering: ordering)
        precondition(!result.oldValue.subtractingReportingOverflow(operand).overflow, "atomic subtract overflowed")
        return result
    }

    /// Stores the larger of the current value and `operand` (a compare-exchange loop: lock-free, not wait-free).
    @inlinable @discardableResult
    public func max(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        var current = load(ordering: .relaxed)
        while true {
            let desired = Swift.max(current, operand)
            let result = compareExchange(expected: current, desired: desired, ordering: ordering)
            if result.exchanged { return (current, desired) }
            current = result.original
        }
    }

    /// Stores the smaller of the current value and `operand` (a compare-exchange loop: lock-free, not wait-free).
    @inlinable @discardableResult
    public func min(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        var current = load(ordering: .relaxed)
        while true {
            let desired = Swift.min(current, operand)
            let result = compareExchange(expected: current, desired: desired, ordering: ordering)
            if result.exchanged { return (current, desired) }
            current = result.original
        }
    }
}

// MARK: - Owned atomic

/// One atomic word, allocated at `init` and freed with the last copy. Copies share the word.
public struct Atomic<Value: AtomicRepresentable>: @unchecked Sendable {
    // @unchecked: the buffer is written at init only; its single element is accessed only atomically.
    @usableFromInline let storage: ManagedBuffer<Void, Value.AtomicRepresentation>

    public init(_ initialValue: Value) {
        storage = .create(minimumCapacity: 1) { _ in }
        storage.withUnsafeMutablePointerToElements { word in
            word.initialize(to: Value.encodeAtomicRepresentation(initialValue))
        }
    }

    /// The operations on the owned word. Its address is stable: a `ManagedBuffer` never moves its elements.
    @inlinable var word: UnsafeAtomic<Value> {
        UnsafeAtomic(at: storage.withUnsafeMutablePointerToElements { $0 })
    }

    @inlinable
    public func load(ordering: AtomicLoadOrdering) -> Value {
        defer { withExtendedLifetime(storage) {} }
        return word.load(ordering: ordering)
    }

    @inlinable
    public func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        defer { withExtendedLifetime(storage) {} }
        word.store(desired, ordering: ordering)
    }

    /// Stores `desired` and returns the previous value.
    @inlinable @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        defer { withExtendedLifetime(storage) {} }
        return word.exchange(desired, ordering: ordering)
    }

    /// Stores `desired` if the current value is `expected` (strong: no spurious failure).
    @inlinable
    public func compareExchange(expected: Value, desired: Value, ordering: AtomicUpdateOrdering)
        -> (exchanged: Bool, original: Value)
    {
        defer { withExtendedLifetime(storage) {} }
        return word.compareExchange(expected: expected, desired: desired, ordering: ordering)
    }
}

extension Atomic where Value: AtomicInteger {
    @inlinable @discardableResult
    public func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.wrappingAdd(operand, ordering: ordering)
    }

    @inlinable @discardableResult
    public func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering)
        -> (oldValue: Value, newValue: Value)
    {
        defer { withExtendedLifetime(storage) {} }
        return word.wrappingSubtract(operand, ordering: ordering)
    }

    /// Adds `operand` and traps on overflow.
    @inlinable @discardableResult
    public func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.add(operand, ordering: ordering)
    }

    /// Subtracts `operand` and traps on overflow.
    @inlinable @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.subtract(operand, ordering: ordering)
    }

    /// Stores the larger of the current value and `operand`.
    @inlinable @discardableResult
    public func max(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.max(operand, ordering: ordering)
    }

    /// Stores the smaller of the current value and `operand`.
    @inlinable @discardableResult
    public func min(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.min(operand, ordering: ordering)
    }
}
