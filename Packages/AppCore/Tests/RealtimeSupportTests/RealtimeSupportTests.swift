// SPDX-License-Identifier: LicenseRef-App-Pending
import Dispatch
import Testing
@testable import RealtimeSupport

@Suite struct SPSCRingTests {
    @Test func fifoAndCapacity() {
        let ring = SPSCRing<Int>(capacity: 4)
        for value in 0..<4 { #expect(ring.push(value)) }
        #expect(!ring.push(99))
        #expect(ring.pop() == 0)
        #expect(ring.push(4))
        #expect([ring.pop(), ring.pop(), ring.pop(), ring.pop(), ring.pop()] == [1, 2, 3, 4, nil])
    }

    @Test func producerConsumerThreads() async {
        let ring = SPSCRing<Int>(capacity: 64)
        let count = 100_000
        let producer = Task.detached {
            var next = 0
            while next < count { if ring.push(next) { next += 1 } }
        }
        var expected = 0
        while expected < count {
            if let value = ring.pop() {
                #expect(value == expected)
                expected += 1
            }
        }
        await producer.value
    }
}

@Suite struct SnapshotCellTests {
    @Test func readSeesLatestPublication() {
        let epoch = ReaderEpoch()
        let cell = SnapshotCell([1], epoch: epoch)
        epoch.enter()
        #expect(cell.read { $0 } == [1])
        epoch.exit()
        cell.publish([2])
        epoch.enter()
        #expect(cell.read { $0.first } == 2)
        epoch.exit()
        #expect(cell.load() == [2])
    }

    @Test func concurrentReaderAndWriter() async {
        let epoch = ReaderEpoch()
        let cell = SnapshotCell(Array(repeating: 0, count: 8), epoch: epoch)
        let writer = Task.detached {
            for value in 1...20_000 { cell.publish(Array(repeating: value, count: 8)) }
        }
        var last = 0
        for _ in 0..<20_000 {
            epoch.enter()
            let values = cell.read { $0 }
            epoch.exit()
            #expect(Set(values).count == 1)  // never a torn or freed value
            #expect(values[0] >= last)
            last = values[0]
        }
        await writer.value
        cell.reclaim()
    }
}

@Suite struct InlineUTF16Tests {
    @Test func capacityAndRoundTrip() {
        #expect(InlineUTF16("ệ")?.string == "ệ")
        #expect(InlineUTF16(String(repeating: "a", count: 20)) != nil)
        #expect(InlineUTF16(String(repeating: "a", count: 21)) == nil)
        #expect(InlineUTF16("ab") == InlineUTF16("ab"))
    }
}
