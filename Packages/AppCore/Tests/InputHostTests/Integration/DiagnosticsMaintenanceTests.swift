// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The W1-A diagnostics wiring request: log rotation at launch and every 6 hours, capture purge at launch and
// hourly (PLT-R903, PLT-R905), and one redaction salt per installation (PLT-R1203). Workstream W2-A.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import Synchronization
import TestSupport
import Testing

@testable import InputHost

/// In-memory `SaltStorage`.
final class InMemorySaltStorage: SaltStorage {
    private let values = Mutex<[String: Data]>([:])
    var writes: Int { writeCount.withLock { $0 } }
    private let writeCount = Mutex(0)

    func data(forKey key: String) -> Data? { values.withLock { $0[key] } }
    func set(_ data: Data, forKey key: String) {
        values.withLock { $0[key] = data }
        writeCount.withLock { $0 += 1 }
    }
}

/// Counts what the maintenance ran and when.
final class MaintenanceRecorder: Sendable {
    private let state = Mutex<(rotations: Int, purges: [Date])>((0, []))
    var rotations: Int { state.withLock { $0.rotations } }
    var purges: [Date] { state.withLock { $0.purges } }
    func rotate() { state.withLock { $0.rotations += 1 } }
    func purge(_ now: Date) { state.withLock { $0.purges.append(now) } }
}

@Suite("Diagnostics maintenance and redaction salt (W1-A request)")
struct DiagnosticsMaintenanceTests {
    @Test func rotatesAtLaunchAndEverySixHoursAndPurgesHourly_PLT_R903_PLT_R905() {
        let scheduler = ManualScheduler(clock: ManualClock())
        let recorder = MaintenanceRecorder()
        let wallClock = FixedWallClock()
        let maintenance = DiagnosticsMaintenance(
            wallClock: wallClock, rotate: { recorder.rotate() }, purge: { recorder.purge($0) })
        let timers = maintenance.start(on: scheduler)
        #expect(recorder.rotations == 0, "the launch run happens on the scheduler's queue, not inline")
        scheduler.advance(by: .zero)
        #expect(recorder.rotations == 1)
        #expect(recorder.purges == [wallClock.now()])
        scheduler.advance(by: .seconds(3_600))
        #expect(recorder.purges.count == 2)
        #expect(recorder.rotations == 1)
        scheduler.advance(by: .seconds(5 * 3_600))
        #expect(recorder.rotations == 2)
        #expect(recorder.purges.count == 7)
        #expect(scheduler.repeatingIntervals.sorted() == [.seconds(3_600), .seconds(6 * 3_600)])
        for timer in timers { timer.cancel() }
        #expect(scheduler.pendingCount == 0)
    }

    @Test func theSaltIsCreatedOnceAndThenReused_PLT_R1203() {
        let storage = InMemorySaltStorage()
        let first = RedactionSaltStore.load(from: storage)
        #expect(first.bytes.count > 0)
        #expect(storage.writes == 1)
        let second = RedactionSaltStore.load(from: storage)
        #expect(second.bytes == first.bytes, "stable across launches of one installation")
        #expect(storage.writes == 1)
    }

    /// `RedactionSalt` requires 32 bytes; a damaged stored value is replaced instead of trapping.
    @Test(arguments: [Data(), Data([1, 2, 3, 4, 5]), Data(count: 33)])
    func aDamagedStoredSaltIsReplaced(stored: Data) {
        let storage = InMemorySaltStorage()
        storage.set(stored, forKey: RedactionSaltStore.key)
        let salt = RedactionSaltStore.load(from: storage)
        #expect(salt.bytes.count == RedactionSaltStore.length)
        #expect(storage.data(forKey: RedactionSaltStore.key) == Data(salt.bytes))
    }
}
