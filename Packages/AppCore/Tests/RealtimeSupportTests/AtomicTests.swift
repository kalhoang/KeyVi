// SPDX-License-Identifier: GPL-3.0-or-later
//
// ADR 0315: RealtimeSupport's `Atomic` and `UnsafeAtomic` replace the macOS 15 `Synchronization.Atomic` with the
// same call shape. Value semantics per width, read-modify-write results, and exact totals under contention.

import Dispatch
import Testing

@testable import RealtimeSupport

@Suite struct AtomicValueTests {
    @Test func loadStoreAndExchangeRoundTripEveryWidth() {
        let small = Atomic<UInt8>(7)
        small.store(200, ordering: .releasing)
        #expect(small.load(ordering: .acquiring) == 200)
        #expect(small.exchange(9, ordering: .acquiringAndReleasing) == 200)
        #expect(small.load(ordering: .relaxed) == 9)

        let signed = Atomic<Int8>(-5)
        #expect(signed.exchange(-128, ordering: .sequentiallyConsistent) == -5)
        #expect(signed.load(ordering: .sequentiallyConsistent) == -128)

        let middle = Atomic<UInt32>(.max)
        #expect(middle.load(ordering: .relaxed) == .max)
        let negative = Atomic<Int32>(.min)
        #expect(negative.load(ordering: .relaxed) == .min)

        let wide = Atomic<UInt64>(.max)
        wide.store(1 << 63, ordering: .sequentiallyConsistent)
        #expect(wide.load(ordering: .sequentiallyConsistent) == 1 << 63)

        let word = Atomic<Int>(-1)
        #expect(word.load(ordering: .relaxed) == -1)
        let unsignedWord = Atomic<UInt>(UInt.max)
        #expect(unsignedWord.exchange(0, ordering: .relaxed) == .max)
        let int64 = Atomic<Int64>(.min)
        #expect(int64.load(ordering: .relaxed) == .min)
    }

    @Test func boolStoresAsAByte() {
        let flag = Atomic<Bool>(false)
        #expect(!flag.exchange(true, ordering: .sequentiallyConsistent))
        #expect(flag.exchange(true, ordering: .sequentiallyConsistent))
        flag.store(false, ordering: .releasing)
        #expect(!flag.load(ordering: .acquiring))
    }

    @Test func unmanagedReferencesRoundTrip() {
        final class Box: Sendable {
            let value: Int
            init(_ value: Int) { self.value = value }
        }
        let first = Unmanaged.passRetained(Box(1))
        let second = Unmanaged.passRetained(Box(2))
        let cell = Atomic(first)
        #expect(cell.load(ordering: .acquiring).takeUnretainedValue().value == 1)
        let old = cell.exchange(second, ordering: .acquiringAndReleasing)
        #expect(old.toOpaque() == first.toOpaque())
        #expect(cell.load(ordering: .acquiring).takeUnretainedValue().value == 2)
        first.release()
        second.release()
    }

    @Test func compareExchangeReportsWhatItFound() {
        let value = Atomic<Int>(10)
        let missed = value.compareExchange(expected: 3, desired: 4, ordering: .acquiringAndReleasing)
        #expect(!missed.exchanged)
        #expect(missed.original == 10)
        #expect(value.load(ordering: .relaxed) == 10)

        let hit = value.compareExchange(expected: 10, desired: 11, ordering: .releasing)
        #expect(hit.exchanged)
        #expect(hit.original == 10)
        #expect(value.load(ordering: .relaxed) == 11)

        // Every update ordering is accepted, including the ones whose failure ordering must drop the release.
        for ordering in [AtomicUpdateOrdering.relaxed, .acquiring, .releasing, .acquiringAndReleasing] {
            #expect(!value.compareExchange(expected: 0, desired: 1, ordering: ordering).exchanged)
        }
        let flag = Atomic<Bool>(false)
        #expect(flag.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged)
        #expect(!flag.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged)
    }

    @Test func wrappingArithmeticWrapsAtTheWidth() {
        let byte = Atomic<UInt8>(250)
        let added = byte.wrappingAdd(10, ordering: .relaxed)
        #expect(added.oldValue == 250)
        #expect(added.newValue == 4)
        #expect(byte.load(ordering: .relaxed) == 4)
        let subtracted = byte.wrappingSubtract(5, ordering: .relaxed)
        #expect(subtracted.oldValue == 4)
        #expect(subtracted.newValue == 255)

        let signed = Atomic<Int>(.max)
        #expect(signed.wrappingAdd(1, ordering: .relaxed).newValue == .min)
        #expect(signed.wrappingSubtract(1, ordering: .relaxed).newValue == .max)
        let negative = Atomic<Int32>(-3)
        #expect(negative.wrappingAdd(5, ordering: .acquiringAndReleasing) == (-3, 2))
        #expect(negative.wrappingSubtract(4, ordering: .sequentiallyConsistent) == (2, -2))
    }

    @Test func checkedArithmeticReturnsBothValues() {
        let counter = Atomic<Int>(1)
        #expect(counter.add(2, ordering: .relaxed) == (1, 3))
        #expect(counter.subtract(5, ordering: .relaxed) == (3, -2))
        #expect(counter.load(ordering: .relaxed) == -2)
    }

    @Test func maxAndMinKeepTheExtreme() {
        let bound = Atomic<UInt64>(5)
        #expect(bound.max(3, ordering: .sequentiallyConsistent) == (5, 5))
        #expect(bound.max(9, ordering: .sequentiallyConsistent) == (5, 9))
        #expect(bound.min(12, ordering: .relaxed) == (9, 9))
        #expect(bound.min(2, ordering: .relaxed) == (9, 2))
        let signed = Atomic<Int>(-4)
        #expect(signed.max(-7, ordering: .relaxed).newValue == -4)
        #expect(signed.min(-7, ordering: .relaxed).newValue == -7)
    }

    @Test func copiesShareOneWord() {
        let original = Atomic<Int>(0)
        let copy = original
        copy.store(42, ordering: .releasing)
        #expect(original.load(ordering: .acquiring) == 42)
    }

    @Test func unsafeAtomicOperatesOnForeignMemory() {
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
        words.initialize(repeating: 0, count: 2)
        defer { words.deallocate() }
        let second = UnsafeAtomic<UInt>(at: words + 1)
        second.store(5, ordering: .releasing)
        #expect(second.wrappingAdd(2, ordering: .relaxed).newValue == 7)
        #expect(second.exchange(1, ordering: .sequentiallyConsistent) == 7)
        #expect(second.compareExchange(expected: 1, desired: 3, ordering: .acquiringAndReleasing).exchanged)
        #expect(words[0] == 0)
        #expect(words[1] == 3)
        #expect(second.address == words + 1)
    }
}

@Suite struct AtomicContentionTests {
    /// Eight threads, each adding and subtracting: no update is lost (each RMW is one atomic instruction).
    @Test func concurrentReadModifyWritesLoseNothing() {
        let counter = Atomic<Int>(0)
        let bytes = Atomic<UInt8>(0)
        let peak = Atomic<Int>(0)
        let perThread = StressScale.isThreadSanitized ? 10_000 : 100_000
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            var index = 0
            while index < perThread {
                counter.wrappingAdd(2, ordering: .relaxed)
                counter.wrappingSubtract(1, ordering: .relaxed)
                bytes.wrappingAdd(1, ordering: .relaxed)
                index += 1
            }
            peak.max(thread, ordering: .relaxed)
        }
        #expect(counter.load(ordering: .sequentiallyConsistent) == 8 * perThread)
        #expect(bytes.load(ordering: .sequentiallyConsistent) == UInt8(truncatingIfNeeded: 8 * perThread))
        #expect(peak.load(ordering: .sequentiallyConsistent) == 7)
    }

    /// A compare-exchange spin lock built on `Atomic<Bool>` protects a plain counter: acquire/release pair up.
    @Test func compareExchangeGivesMutualExclusion() {
        final class Shared: @unchecked Sendable {
            let locked = Atomic<Bool>(false)
            var value = 0
        }
        let shared = Shared()
        let perThread = StressScale.isThreadSanitized ? 2_000 : 20_000
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            var index = 0
            while index < perThread {
                while !shared.locked.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {}
                shared.value += 1
                shared.locked.store(false, ordering: .releasing)
                index += 1
            }
        }
        #expect(shared.value == 4 * perThread)
    }
}
