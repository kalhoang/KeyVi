// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W1-A acceptance: the snapshot read path, SPSCRing.push/pop, Log2Histogram.record and TapLogRing.push make
// zero heap allocations (PLT-R304, PLT-R305). Every measured loop uses `while`: a debug-build `for-in` over a
// range allocates an iterator box per iteration.

import Dispatch
import Testing

@testable import Diagnostics
@testable import RealtimeSupport
@testable import TestSupport

private struct TapLikeSnapshot: Sendable {
    var mode: UInt8
    var flags: UInt64
    var table: [UInt16]
}

/// Runs `operation` once to warm up lazy metadata, then counts allocations over `iterations` more calls.
/// The calls always happen; the count is nil when counting is unavailable (Thread Sanitizer replaces malloc).
private func allocations(iterations: Int = 10_000, _ operation: () -> Void) -> Int? {
    operation()
    func repeatOperation() {
        var index = 0
        while index < iterations {
            operation()
            index += 1
        }
    }
    guard AllocationCounter.isAvailable else {
        repeatOperation()
        return nil
    }
    return AllocationCounter.count(repeatOperation)
}

/// Zero in plain runs; under a sanitizer that replaces malloc the count is unavailable and only the other
/// expectations of the test apply.
private func expectNoAllocations(_ count: Int?, sourceLocation: SourceLocation = #_sourceLocation) {
    guard !AllocationCounter.isSanitizerActive else { return }
    #expect(count == 0, sourceLocation: sourceLocation)
}

@Suite(.serialized) struct HotPathAllocationTests {
    @Test func counterSeesAKnownAllocation() throws {
        try #require(AllocationCounter.isAvailable || AllocationCounter.isSanitizerActive)
        guard AllocationCounter.isAvailable else { return }
        final class Probe: Sendable {}
        let counted = AllocationCounter.count {
            var index = 0
            while index < 10 {
                Unmanaged.passRetained(Probe()).release()
                index += 1
            }
        }
        #expect((counted ?? 0) >= 10)
    }

    /// Negative control through library code: `publish` boxes every value, and the counter must see it.
    @Test func publishingAllocatesAndIsSeen() {
        guard AllocationCounter.isAvailable else { return }
        let cell = SnapshotCell(1, epoch: ReaderEpoch())
        let count = allocations(iterations: 100) { cell.publish(2) }
        #expect((count ?? 0) >= 100)
    }

    @Test func snapshotReadPathAllocatesNothing() {
        let epoch = ReaderEpoch()
        let cell = SnapshotCell(
            TapLikeSnapshot(mode: 1, flags: 0, table: Array(repeating: 7, count: 128)), epoch: epoch)
        var sink: UInt64 = 0
        let count = allocations {
            epoch.enter()
            sink &+= cell.read { snapshot in UInt64(snapshot.mode) &+ snapshot.flags &+ UInt64(snapshot.table[3]) }
            epoch.exit()
        }
        expectNoAllocations(count)
        #expect(sink > 0)
    }

    @Test func spscPushAndPopAllocateNothing() {
        let ring = SPSCRing<TapLogRecord>(capacity: 64)
        let record = TapLogRecord(code: .echoMissing, at: MonotonicInstant(nanoseconds: 9), a: 1, b: 2)
        var popped: UInt64 = 0
        let count = allocations {
            _ = ring.push(record)
            popped &+= ring.pop()?.a ?? 0
        }
        expectNoAllocations(count)
        #expect(popped > 0)
    }

    @Test func histogramRecordAllocatesNothing() {
        let histogram = Log2Histogram()
        var value: UInt64 = 1
        let count = allocations {
            histogram.record(nanoseconds: value)
            value = value &* 3 &+ 1
        }
        expectNoAllocations(count)
        #expect(histogram.snapshot().count == 10_001)
    }

    @Test func tapLogPushAllocatesNothingEvenWhenFull() {
        let ring = TapLogRing(capacity: 16)
        let record = TapLogRecord(code: .flushRequested, at: .zero, a: 3)
        let count = allocations { ring.push(record) }
        expectNoAllocations(count)
        #expect(ring.droppedCount > 0)
    }

    @Test func countersClockEpochAndCaptureFlagAllocateNothing() {
        let counter = AtomicCounter()
        let clock = MachClock()
        let epoch = ReaderEpoch()
        let array = AtomicUInt64Array(count: 4)
        let capture = CaptureFixture.make().controller
        var sink: UInt64 = 0
        let count = allocations {
            counter.increment()
            epoch.enter()
            sink &+= clock.now().nanoseconds
            epoch.exit()
            array.increment(2)
            if capture.isRecording { sink &+= 1 }
        }
        expectNoAllocations(count)
        #expect(counter.value == 10_001)
        #expect(sink > 0)
    }

    @Test func tapSignalsAllocateNothing() {
        let wake = WakeSignal(queue: DispatchQueue(label: "test.alloc.wake")) {}
        let worker = WorkerSignal()
        let count = allocations {
            wake.signal()
            worker.signal()
        }
        wake.cancel()
        expectNoAllocations(count)
    }

    @Test func signpostsAllocateNothingWhenNotRecording() {
        let signposts = PlatformSignposts(subsystem: "test.signposts")
        let count = allocations {
            let token = signposts.begin(.tapCallback)
            signposts.end(.tapCallback, token)
        }
        expectNoAllocations(count)
    }
}
