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

    /// Retest of 15/11/2026, items 7 and 9: Spotlight's field on macOS 27.2 lost one deletion per edit, and the
    /// trace could not tell whether AX reported no selection or could not answer. A job whose plan reads the inline
    /// completion through AX (PLT-R420) records what the read found; other jobs record nothing.
    @Test func theInlineCompletionReadIsRecordedPLTR420() throws {
        func completionLabel(
            _ field: SimulatedTextField, ax: FakeFocusedFieldAccess.Behaviour = .normal,
            mode: InlineCompletionMode = .axSelection
        ) throws -> String? {
            let clock = ManualClock()
            let capture = try recordingCapture(clock: clock)
            let rig = WorkerRig(field: field, capture: capture)
            rig.fieldAccess.setBehaviour(ax)
            let plan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = mode })
            rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
            rig.run()
            guard case .job(let job)? = devRecords(capture).last else {
                Issue.record("a job record")
                return nil
            }
            return job.completion?.description
        }
        let suggesting = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
        let typed = InjectionFieldWiring.keyDown("a", receivedAt: Fixture.start)
        suggesting.apply(typed, layout: InjectionTestLayouts.qwerty())
        #expect(try completionLabel(suggesting) == "selected")
        #expect(try completionLabel(SimulatedTextField(text: "a")) == "none")
        #expect(try completionLabel(SimulatedTextField(text: "a"), ax: .timeout) == "unreadable")
        #expect(try completionLabel(SimulatedTextField(text: "a"), ax: .unavailable) == "unreadable")
        #expect(try completionLabel(SimulatedTextField(text: "a"), mode: .none) == nil)
        #expect(try completionLabel(SimulatedTextField(text: "a"), mode: .placeholder) == nil)
    }

    /// PLT-R423: what the `forwardDelete` read decided, and the events it cost (a Forward Delete pair before the
    /// Backspace pair of a delete-1 job: 6 events instead of 4).
    @Test func theForwardDeleteDecisionIsRecordedPLTR423() throws {
        func record(
            _ field: SimulatedTextField, ax: FakeFocusedFieldAccess.Behaviour = .normal
        ) throws -> (label: String?, events: Int) {
            let clock = ManualClock()
            let capture = try recordingCapture(clock: clock)
            let rig = WorkerRig(field: field, capture: capture)
            rig.fieldAccess.setBehaviour(ax)
            let plan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = .forwardDelete })
            rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan) }
            rig.run()
            guard case .job(let job)? = devRecords(capture).last else {
                Issue.record("a job record")
                return (nil, 0)
            }
            return (job.completion?.description, job.eventsPosted)
        }
        let atEnd = try record(SimulatedTextField(text: "a"))
        #expect(atEnd.label == "forwardDelete" && atEnd.events == 6)
        let middle = SimulatedTextField(text: "ab")
        middle.click(at: 1)
        let notAtEnd = try record(middle)
        #expect(notAtEnd.label == "forwardDelete skipped notAtEnd" && notAtEnd.events == 4)
        let unreadable = try record(SimulatedTextField(text: "a"), ax: .timeout)
        #expect(unreadable.label == "forwardDelete skipped unreadable" && unreadable.events == 4)
        let selecting = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
        selecting.apply(
            InjectionFieldWiring.keyDown("a", receivedAt: Fixture.start), layout: InjectionTestLayouts.qwerty())
        let selected = try record(selecting)
        #expect(selected.label == "selected" && selected.events == 6)
    }

    /// Retest of 16/11/2026, items 34 and 40: Spotlight answered the PLT-R423 read just past the 15 ms bound while it
    /// was opening. The job line carries how long the completion read took, timeouts included, so the bounds (50 ms
    /// for `forwardDelete`, 15 ms for `axSelection`) can be tuned from traces; a job that made no read carries none.
    @Test func theCompletionReadDurationIsRecordedPLTR904A() throws {
        func record(
            _ mode: InlineCompletionMode, latency: TimeSpan, field: FieldHandle? = Fixture.field
        ) throws -> (label: String?, microseconds: UInt64?) {
            let clock = ManualClock()
            let capture = try recordingCapture(clock: clock)
            let rig = WorkerRig(field: SimulatedTextField(text: "a"), capture: capture)
            rig.fieldAccess.setReadLatency(latency, clock: rig.clock)
            let plan = Fixture.plan(parameters: Fixture.parameters { $0.inlineCompletion = mode })
            rig.pushEdit { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á", plan: plan, field: field) }
            rig.run()
            guard case .job(let job)? = devRecords(capture).last else {
                Issue.record("a job record")
                return (nil, nil)
            }
            return (job.completion?.description, job.completionReadMicroseconds)
        }
        let answered = try record(.forwardDelete, latency: .microseconds(23_400))
        #expect(answered.label == "forwardDelete" && answered.microseconds == 23_400)
        let late = try record(.forwardDelete, latency: .milliseconds(80))
        #expect(late.label == "forwardDelete skipped unreadable" && late.microseconds == 50_000)
        let noField = try record(.forwardDelete, latency: .milliseconds(1), field: nil)
        #expect(noField.label == "forwardDelete skipped unreadable" && noField.microseconds == nil)
        let selectionLate = try record(.axSelection, latency: .milliseconds(20))
        #expect(selectionLate.label == "unreadable" && selectionLate.microseconds == 15_000)
        let selection = try record(.axSelection, latency: .microseconds(480))
        #expect(selection.label == "none" && selection.microseconds == 480)
        let noRead = try record(.none, latency: .milliseconds(1))
        #expect(noRead.label == nil && noRead.microseconds == nil)
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
