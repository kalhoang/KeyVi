// SPDX-License-Identifier: LicenseRef-App-Pending
//
// ADR 0315: the settings store runs on its own `QueueExecutor` (the utility serial queue, PLT-R203) on every
// system, and debounce timers enter it with `withQueueIsolation` instead of `assumeIsolated`.

import AppModel
import Dispatch
import Foundation
import TestSupport
import Testing

@testable import SettingsStore

@Suite struct QueueExecutorTests {
    fileprivate static let marker = DispatchSpecificKey<String>()

    private actor Probe {
        let executor: QueueExecutor
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        private var order: [Int] = []

        init(queue: DispatchQueue) { executor = QueueExecutor(queue: queue) }

        /// Records `value` and the queue the job ran on.
        func record(_ value: Int) -> String? {
            order.append(value)
            return DispatchQueue.getSpecific(key: QueueExecutorTests.marker)
        }

        var recorded: [Int] { order }
    }

    @Test func actorJobsRunOnTheQueue() async {
        let queue = DispatchQueue(label: "test.queue-executor")
        queue.setSpecific(key: Self.marker, value: "utility")
        let probe = Probe(queue: queue)
        for value in 0..<20 {
            #expect(await probe.record(value) == "utility")
        }
        #expect(await probe.recorded == Array(0..<20))
    }

    @Test func storeJobsRunOnItsQueue() async {
        let queue = DispatchQueue(label: "test.settings-store-queue")
        queue.setSpecific(key: Self.marker, value: "store")
        let store = SettingsStore(
            location: StorageLocation(directory: URL(fileURLWithPath: "/Settings")), fileSystem: InMemoryFileSystem(),
            wallClock: FixedWallClock(), writtenBy: "0.1.0", queue: queue,
            launchGuard: LaunchGuard(store: InMemoryKeyValueStore()), onChange: { _ in })
        #expect(await store.executor.queue === queue)
        _ = await store.load()
        let ranOn = await store.runningQueueMarker()
        #expect(ranOn == "store")
    }

    /// A block already on the store's queue (a debounce timer hop) gets the store's isolation without
    /// `assumeIsolated`, and sees the state the store's own jobs wrote.
    @Test func withQueueIsolationEntersTheStoreFromItsQueue() async {
        let harness = SettingsStoreHarness()
        let generation = await harness.store.load().generation
        let queue = await harness.store.queue
        let seen: UInt64 = await withCheckedContinuation { done in
            queue.async {
                harness.store.withQueueIsolation { store in done.resume(returning: store.generation) }
            }
        }
        #expect(seen == generation)
    }
}

extension SettingsStore {
    fileprivate func runningQueueMarker() -> String? { DispatchQueue.getSpecific(key: QueueExecutorTests.marker) }
}
