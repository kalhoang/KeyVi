// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W1-A acceptance: 10 million concurrent publish/read iterations never observe a torn or freed value
// (PLT-R388, docs/decisions/0303-snapshot-publication.md).

import Synchronization
import Testing

@testable import RealtimeSupport

/// Counts live payloads so the tests can prove every retired box is eventually freed exactly once.
private let livePayloads = Atomic<Int>(0)

private final class Payload: Sendable {
    static let aliveMagic: UInt64 = 0xA11C_E5ED_0000_0001
    let generation: UInt64
    let magic: Atomic<UInt64>

    init(generation: UInt64) {
        self.generation = generation
        magic = Atomic(Self.aliveMagic)
        livePayloads.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    deinit {
        // A reader that still sees this object after deinit observes a different magic value.
        magic.store(0xDEAD_DEAD_DEAD_DEAD, ordering: .sequentiallyConsistent)
        livePayloads.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }
}

/// Snapshot value whose fields are derived from one generation number, so a torn read is detectable.
private struct StressValue: Sendable {
    let generation: UInt64
    let doubled: UInt64
    let inverted: UInt64
    let payload: Payload

    init(_ generation: UInt64) {
        self.generation = generation
        doubled = generation &* 2
        inverted = ~generation
        payload = Payload(generation: generation)
    }

    var isConsistent: Bool {
        doubled == generation &* 2 && inverted == ~generation && payload.generation == generation
            && payload.magic.load(ordering: .relaxed) == Payload.aliveMagic
    }
}

@Suite(.serialized) struct SnapshotCellStressTests {
    @Test func tenMillionConcurrentReadsNeverSeeTornOrFreedValues() async {
        let baseline = livePayloads.load(ordering: .sequentiallyConsistent)
        let epoch = ReaderEpoch()
        let cell = SnapshotCell(StressValue(0), epoch: epoch)
        let readerDone = Atomic<Bool>(false)
        let writer = Task.detached {
            var generation: UInt64 = 1
            while !readerDone.load(ordering: .relaxed) {
                cell.publish(StressValue(generation))
                generation &+= 1
            }
            return generation
        }
        let iterations = StressScale.concurrentIterations
        var torn = 0
        var regressions = 0
        var last: UInt64 = 0
        var index = 0
        while index < iterations {
            epoch.enter()
            let (consistent, generation) = cell.read { ($0.isConsistent, $0.generation) }
            epoch.exit()
            if !consistent { torn += 1 }
            if generation < last { regressions += 1 }
            last = generation
            index += 1
        }
        readerDone.store(true, ordering: .relaxed)
        let published = await writer.value
        #expect(torn == 0)
        #expect(regressions == 0)
        #expect(published > 1)
        cell.reclaim()
        #expect(cell.retiredCount == 0)
        // Only the current box remains alive.
        #expect(livePayloads.load(ordering: .sequentiallyConsistent) == baseline + 1)
    }

    @Test func retiredBoxesWaitForTheReaderToLeave() {
        let baseline = livePayloads.load(ordering: .sequentiallyConsistent)
        let epoch = ReaderEpoch()
        let cell = SnapshotCell(StressValue(1), epoch: epoch)
        epoch.enter()
        let seen = cell.read { $0.generation }
        cell.publish(StressValue(2))
        cell.publish(StressValue(3))
        // The reader may still borrow generation 1, so its box and the boxes retired during the same
        // callback stay alive.
        #expect(cell.retiredCount == 2)
        #expect(cell.read { $0.isConsistent })
        epoch.exit()
        cell.reclaim()
        #expect(cell.retiredCount == 0)
        #expect(seen == 1)
        #expect(cell.load().generation == 3)
        #expect(livePayloads.load(ordering: .sequentiallyConsistent) == baseline + 1)
    }

    @Test func publishOutsideACallbackFreesImmediately() {
        let epoch = ReaderEpoch()
        let cell = SnapshotCell(StressValue(1), epoch: epoch)
        for generation: UInt64 in 2...50 { cell.publish(StressValue(generation)) }
        #expect(cell.retiredCount == 0)
    }

    @Test func deinitReleasesCurrentAndRetiredBoxes() {
        let baseline = livePayloads.load(ordering: .sequentiallyConsistent)
        do {
            let epoch = ReaderEpoch()
            let cell = SnapshotCell(StressValue(1), epoch: epoch)
            epoch.enter()
            cell.publish(StressValue(2))
            #expect(cell.retiredCount == 1)
            epoch.exit()
        }
        #expect(livePayloads.load(ordering: .sequentiallyConsistent) == baseline)
    }

    @Test func epochCountsEntriesAndExits() {
        let epoch = ReaderEpoch()
        #expect(epoch.value == 0)
        epoch.enter()
        #expect(epoch.value & 1 == 1)
        epoch.exit()
        #expect(epoch.value == 2)
    }
}
