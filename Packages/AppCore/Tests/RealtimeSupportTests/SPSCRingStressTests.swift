// SPDX-License-Identifier: LicenseRef-App-Pending
//
// SPSC ring under a real producer and consumer thread (PLT-R304 "lock-free single-producer queue").

import Testing

@testable import RealtimeSupport

private let liveElements = Atomic<Int>(0)

private final class Tracked: Sendable {
    let value: Int
    init(_ value: Int) {
        self.value = value
        liveElements.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }
    deinit { liveElements.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
}

@Suite(.serialized) struct SPSCRingStressTests {
    @Test func tenMillionTransfersKeepOrderAcrossThreads() async {
        let ring = SPSCRing<UInt64>(capacity: 1024)
        let count = UInt64(StressScale.concurrentIterations)
        let producer = Task.detached {
            var next: UInt64 = 0
            var fullRetries = 0
            while next < count {
                if ring.push(next) { next += 1 } else { fullRetries += 1 }
            }
            return fullRetries
        }
        var expected: UInt64 = 0
        var outOfOrder = 0
        while expected < count {
            if let value = ring.pop() {
                if value != expected { outOfOrder += 1 }
                expected += 1
            }
        }
        _ = await producer.value
        #expect(outOfOrder == 0)
        #expect(ring.pop() == nil)
        #expect(ring.count == 0)
    }

    @Test func elementsAreDestroyedExactlyOnce() {
        let baseline = liveElements.load(ordering: .sequentiallyConsistent)
        do {
            let ring = SPSCRing<Tracked>(capacity: 8)
            for value in 0..<6 { #expect(ring.push(Tracked(value))) }
            #expect(ring.count == 6)
            #expect(ring.pop()?.value == 0)
            #expect(ring.pop()?.value == 1)
            // Four elements remain inside the ring; deinit must destroy them.
            #expect(liveElements.load(ordering: .sequentiallyConsistent) == baseline + 4)
        }
        #expect(liveElements.load(ordering: .sequentiallyConsistent) == baseline)
    }

    @Test func wrapsAroundManyTimes() {
        let ring = SPSCRing<Int>(capacity: 2)
        var popped: [Int] = []
        for value in 0..<1_000 {
            #expect(ring.push(value))
            popped.append(ring.pop() ?? -1)
        }
        #expect(popped == Array(0..<1_000))
        #expect(ring.capacity == 2)
    }

    @Test func rejectsCapacityThatIsNotAPowerOfTwo() async {
        await #expect(processExitsWith: .failure) {
            _ = SPSCRing<Int>(capacity: 3)
        }
    }
}
