// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R392: the ax thread's memory documents reach SettingsStore one at a time, in emission order.

import AppModel
import Foundation
import SettingsStore
import Synchronization
import TestSupport
import Testing

@testable import InputHost

@Suite struct AppModesRecorderTests {
    /// A slow first delivery must not let a newer document reach the store first (the store replaces the
    /// remembered modes wholesale, so the older one would win on disk).
    @Test func deliversInEmissionOrderOneAtATime() async {
        let delivered = Mutex<[Int]>([])
        let inFlight = Atomic<Int>(0)
        let overlapped = Atomic<Bool>(false)
        let recorder = AppModesRecorder { document in
            if inFlight.wrappingAdd(1, ordering: .relaxed).newValue > 1 { overlapped.store(true, ordering: .relaxed) }
            if document.apps.isEmpty { try? await Task.sleep(for: .milliseconds(30)) }
            delivered.withLock { $0.append(document.apps.count) }
            inFlight.wrappingSubtract(1, ordering: .relaxed)
        }
        for count in 0..<6 {
            let apps = (0..<count).map { AppModeEntry(bundle: bundle("com.example.app\($0)"), mode: .english) }
            recorder.record(AppModesDocument(globalMode: .english, apps: apps))
        }
        recorder.finish()
        await recorder.finished()
        let order = delivered.withLock { $0 }
        let overlap = overlapped.load(ordering: .relaxed)
        #expect(order == [0, 1, 2, 3, 4, 5])
        #expect(!overlap)
    }

    /// The last document emitted is the one the store keeps.
    @Test func theStoreEndsWithTheLastEmittedDocument() async {
        let store = SettingsStoreHarness()
        _ = await store.store.load()
        let recorder = AppModesRecorder(store: store.store)
        var last = AppModesDocument()
        for index in 0..<20 {
            last = AppModesDocument(
                globalMode: index.isMultiple(of: 2) ? .english : .vietnamese,
                apps: [AppModeEntry(bundle: bundle("com.example.app\(index)"), mode: .english)])
            recorder.record(last)
        }
        recorder.finish()
        await recorder.finished()
        let stored = await store.store.state.appModes
        #expect(stored.globalMode == last.globalMode)
        #expect(stored.apps.first?.bundle == last.apps.first?.bundle)
    }
}
