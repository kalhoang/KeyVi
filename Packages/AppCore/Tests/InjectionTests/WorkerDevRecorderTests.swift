// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): the inject thread's records for the dev recorder: every edit job with its kind, strategy,
// outcome, events posted and durations, and every strategy fallback with its reason.

#if DEV_RECORDER
import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private func recordingCapture(clock: ManualClock) throws -> CaptureController {
    let capture = CaptureController(
        directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
        fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
        scheduler: ManualScheduler(clock: clock))
    try capture.dev.start(appVersion: "test")
    return capture
}

private func devRecords(_ capture: CaptureController) -> [DevTraceRecord] {
    var records: [DevTraceRecord] = []
    while let record = capture.dev.injectRecords.pop() { records.append(record) }
    return records
}

@Suite struct WorkerDevRecorderTests {
    @Test func everyEditJobIsRecordedWithItsOutcomeAndCost() throws {
        let field = SimulatedTextField(text: "a")
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let rig = WorkerRig(field: field, capture: capture)
        rig.clock.sleep(until: Fixture.start.advanced(byMicroseconds: 4_000))
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "â", kind: .backspaceRecompose) }
        rig.run()
        #expect(field.text == "â")
        let records = devRecords(capture)
        #expect(records.count == 1)
        guard case .job(let job)? = records.first else {
            Issue.record("a job record")
            return
        }
        #expect(String(describing: job.kind) == "backspaceRecompose")
        #expect(job.strategy == .backspaceReplace && job.outcome.description == "executed")
        #expect(job.deleteCount == 1 && job.insertCount == 1 && job.generation == 1)
        #expect(job.eventsPosted == rig.poster.posted.count && job.eventsPosted > 0)
        #expect(job.totalMicroseconds >= 4_000 && job.runMicroseconds <= job.totalMicroseconds)
    }

    @Test func fallbacksAreRecordedWithTheirReason() throws {
        let field = SimulatedTextField(text: "a")
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        let rig = WorkerRig(field: field, capture: capture)
        rig.fieldAccess.setBehaviour(.unavailable)
        rig.pushEdit {
            Fixture.job(
                sequence: $0, deleteCount: 1, insertion: "á",
                plan: Fixture.plan(.axReplace, fallback: [.backspaceReplace]))
        }
        rig.run()
        let records = devRecords(capture)
        guard case .fallback(_, let from, let to, let reason, _)? = records.first,
            case .job(let job)? = records.last
        else {
            Issue.record("a fallback, then the job")
            return
        }
        #expect(from == .axReplace && to == .backspaceReplace && String(describing: reason) == "axUnavailable")
        #expect(job.outcome.description == "executedWithFallback")
    }

    @Test func nothingIsRecordedWhileTheRecorderIsPaused() throws {
        let clock = ManualClock()
        let capture = try recordingCapture(clock: clock)
        capture.dev.pause()
        let rig = WorkerRig(field: SimulatedTextField(text: "a"), capture: capture)
        rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "â") }
        rig.run()
        #expect(devRecords(capture).isEmpty)
    }
}
#endif
