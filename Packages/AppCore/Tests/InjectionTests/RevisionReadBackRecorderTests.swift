// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A with PLT-R357 (retest of 16/11/2026): the job line of a revision says what its read-back found, so a
// trace tells why a revision fell back: a caret the app reports at 0, a read that comes back short (a caret beyond
// the text returned), other text before the caret (read once more after the settle wait), an unreadable field, or no
// read at all (the rule never verifies, the previous token is unknown). Names only, never the text read. Worker in
// step mode over fakes.

#if DEV_RECORDER
import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private let spaceTrigger = KeyCode(rawValue: 0x31)
private let aKey = KeyCode(rawValue: 0x00)

/// `tricky á hell`, `hell` committed: RV1 restores `á` to `as`; the minimal edit deletes six graphemes.
private func revisionJob(
    sequence: UInt64, previous: CommittedToken? = CommittedToken(display: "á"), deleteCount: Int = 6,
    verify: Bool = true
) -> EditJob {
    var job = Fixture.job(
        sequence: sequence, deleteCount: deleteCount, insertion: "as hell", kind: .revision, trigger: nil,
        verifyBeforeApply: verify, keyCodes: JobKeyCodes(trigger: spaceTrigger, firstCharacter: aKey))
    job.revision = RevisionEdit(previous: previous, currentDisplay: "hell")
    return job
}

/// Reports the caret `shift` units after where the field has it: a caret counted in screen cells after a
/// double-width glyph lies beyond the text the app returns.
private struct ShiftedCaretAccess: FocusedFieldAccess {
    let base: any FocusedFieldAccess
    let shift: Int

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        guard case .success(let range) = base.selectedRange(field, timeout: timeout) else { return .unavailable }
        return .success(Injection.TextRange(location: range.location + shift, length: range.length))
    }
    func caret(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldCaret> {
        base.caret(field, timeout: timeout)
    }
    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        base.text(field, in: range, timeout: timeout)
    }
    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        base.setSelectedRange(field, to: range, timeout: timeout)
    }
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        base.setSelectedText(field, to: text, timeout: timeout)
    }
}

private func recordingCapture(clock: ManualClock) throws -> CaptureController {
    let capture = CaptureController(
        directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
        fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
        scheduler: ManualScheduler(clock: clock))
    try capture.dev.start(appVersion: "test")
    return capture
}

/// The job records the rig's worker wrote, in order.
private func jobRecords(_ capture: CaptureController) -> [DevJobRecord] {
    var jobs: [DevJobRecord] = []
    while let record = capture.dev.injectRecords.pop() {
        if case .job(let job) = record { jobs.append(job) }
    }
    return jobs
}

/// Runs `build` in a worker over `text` and returns the label its job record carries and the job's outcome.
private func recorded(
    text: String, caretShift: Int = 0, caretAt: Int? = nil, unreadable: Bool = false,
    _ build: (UInt64) -> EditJob
) throws -> (readback: String?, outcome: JobOutcome?) {
    let capture = try recordingCapture(clock: ManualClock())
    let field = SimulatedTextField(text: text)
    let rig = WorkerRig(
        field: field, fieldAccessWrapper: { ShiftedCaretAccess(base: $0, shift: caretShift) }, capture: capture)
    if unreadable { rig.fieldAccess.setBehaviour(.unavailable) }
    if let caretAt { field.click(at: caretAt) }
    let edit = rig.pushEdit(build)
    rig.run()
    let job = try #require(jobRecords(capture).last)
    return (job.readback?.description, rig.outcome(edit))
}

@Suite struct RevisionReadBackRecorderTests {
    @Test func aMatchingFieldRecordsMatches() throws {
        let result = try recorded(text: "tricky á hell") { revisionJob(sequence: $0) }
        #expect(result.readback == "matches")
        #expect(result.outcome == .executed)
    }

    /// Autocorrect changed the previous word: other text before the caret, read again after the settle wait.
    @Test func otherTextBeforeTheCaretRecordsDiffersAfterTheSettleWait() throws {
        let result = try recorded(text: "tricky a hell") { revisionJob(sequence: $0) }
        #expect(result.readback == "mismatch differs afterSettle")
        #expect(result.outcome == .executedWithFallback)
    }

    /// Warp reports the caret at 0.
    @Test func aCaretAtTheStartRecordsCaretBeforeText() throws {
        let result = try recorded(text: "tricky á hell", caretAt: 0) { revisionJob(sequence: $0) }
        #expect(result.readback == "mismatch caretBeforeText afterSettle")
    }

    /// A caret one unit beyond the text the app returns (a screen-cell index): the read comes back short.
    @Test func aCaretBeyondTheTextRecordsAShortRead() throws {
        let result = try recorded(text: "tricky á hell", caretShift: 1) { revisionJob(sequence: $0) }
        #expect(result.readback == "mismatch shortRead afterSettle")
    }

    /// `verifyReentry: whenReadable`: an unreadable field applies the revision, and says so.
    @Test func anUnreadableFieldRecordsUnreadable() throws {
        let result = try recorded(text: "tricky á hell", unreadable: true) { revisionJob(sequence: $0) }
        #expect(result.readback == "unreadable")
        #expect(result.outcome == .executed)
    }

    /// Terminals (`verifyReentry: never`, retest of 16/11/2026): no read, the revision applies as computed.
    @Test func aRuleThatNeverVerifiesRecordsSkippedRule() throws {
        let result = try recorded(text: "tricky á hell", caretAt: 0) { revisionJob(sequence: $0, verify: false) }
        #expect(result.readback == "skipped rule")
        #expect(result.outcome == .executed)
    }

    /// Without the previous token, or with a deletion wider than it, only the current token's part is applied.
    @Test func noReadOfAnUnknownOrTooShortPreviousToken() throws {
        let unknown = try recorded(text: "tricky á hell") { revisionJob(sequence: $0, previous: nil) }
        #expect(unknown.readback == "skipped unknownPrevious")
        let wide = try recorded(text: "tricky á hell") { revisionJob(sequence: $0, deleteCount: 8) }
        #expect(wide.readback == "skipped wideDeletion")
    }

    /// Only revision jobs carry the field.
    @Test func otherJobsRecordNoReadBack() throws {
        let result = try recorded(text: "a") { Fixture.job(sequence: $0, deleteCount: 1, insertion: "á") }
        #expect(result.readback == nil)
    }
}
#endif
