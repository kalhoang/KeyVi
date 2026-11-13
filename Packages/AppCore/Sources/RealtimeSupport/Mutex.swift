// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Mutual exclusion for macOS 12 and later (docs/decisions/0315-minimum-macos-12.md). The API mirrors the
// `Synchronization` module's `Mutex` (macOS 15): `Mutex(initialValue)` and `withLock { value in ... }`.
//
// Built on `os_unfair_lock`, like `Synchronization.Mutex` on Darwin: no allocation after `init`, waiters sleep
// in the kernel with priority donation, recursion and unlocking from another thread trap. It blocks, so the
// tap thread never takes one (PLT-R304, PLT-R305); the tap reads published snapshots and lock-free atomics.

public import Darwin

/// A value protected by an unfair lock. Copies are handles to the same lock and value.
public struct Mutex<Value>: @unchecked Sendable {
    // @unchecked: the value is reachable only inside `withLock`, while the lock is held.
    @usableFromInline let storage: ManagedBuffer<Value, os_unfair_lock>

    public init(_ initialValue: sending Value) {
        storage = .create(minimumCapacity: 1) { _ in initialValue }
        storage.withUnsafeMutablePointerToElements { lock in lock.initialize(to: os_unfair_lock()) }
    }

    /// Runs `body` with exclusive access to the value. Never call on the tap thread; never nest on one mutex.
    @inlinable
    public func withLock<Result, E: Error>(_ body: (inout sending Value) throws(E) -> sending Result) throws(E)
        -> sending Result
    {
        // The header and element addresses of a `ManagedBuffer` are stable for its whole life.
        let (value, lock) = storage.withUnsafeMutablePointers { ($0, $1) }
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
            withExtendedLifetime(storage) {}
        }
        return try body(&value.pointee)
    }
}
