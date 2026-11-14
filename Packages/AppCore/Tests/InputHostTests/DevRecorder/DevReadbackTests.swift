// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007) field readback: at most 64 UTF-16 units before the caret and the selection, read only in a
// typing pause (no key or click down and no edit job for 1 s; review of Pa's traces of 2026-11-14, incidents 1 and
// 10), at most one read per 300 ms. Each read records how long it waited, how long the input had been idle, how
// long the AX calls took, and whether a key went down while it was in flight. Observer rule: no read where the
// compat rule keeps KeyVi off accessibility (`requireTextFocus: never`), never in a secure field or while secure
// input is on, and only reads (no writes, no AXEnhancedUserInterface or AXManualAccessibility).

#if DEV_RECORDER
import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing

@testable import Diagnostics
@testable import InputHost

/// Models AX's per-element messaging timeout: each call sets the timeout on the element (here: the handle's token)
/// it is made on, as `AXFieldCalls` does. Records which elements were used.
private final class ElementTimeoutFieldAccess: FocusedFieldAccess, Sendable {
    private let base: FakeFocusedFieldAccess
    private let state = Mutex<(timeouts: [UInt64: TimeSpan], tokens: [UInt64])>(([:], []))
    /// Runs after every call (a job starting while the readback reads). Boxed: a bare closure read through a
    /// mutex is re-wrapped on every read.
    final class Hook: Sendable {
        let run: @Sendable () -> Void
        init(_ run: @escaping @Sendable () -> Void) { self.run = run }
    }
    let afterCall = Mutex<Hook?>(nil)

    init(base: FakeFocusedFieldAccess) { self.base = base }

    var timeouts: [UInt64: TimeSpan] { state.withLock { $0.timeouts } }
    var tokens: [UInt64] { state.withLock { $0.tokens } }

    private func note(_ field: FieldHandle, _ timeout: TimeSpan) {
        state.withLock {
            $0.timeouts[field.token] = timeout
            $0.tokens.append(field.token)
        }
        afterCall.withLock { $0 }?.run()
    }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        defer { note(field, timeout) }
        return base.selectedRange(field, timeout: timeout)
    }
    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        defer { note(field, timeout) }
        return base.text(field, in: range, timeout: timeout)
    }
    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan)
        -> AXCallResult<Void>
    {
        defer { note(field, timeout) }
        return base.setSelectedRange(field, to: range, timeout: timeout)
    }
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        defer { note(field, timeout) }
        return base.setSelectedText(field, to: text, timeout: timeout)
    }
}

/// The app answers its focused element with a new reference (token + `privateOffset`), or reports that focus moved.
private final class FakeReadbackFieldResolver: DevReadbackFieldResolver, Sendable {
    static let privateOffset: UInt64 = 1_000
    let focusMoved = Atomic<Bool>(false)
    private let calls = Atomic<Int>(0)
    var callCount: Int { calls.load(ordering: .relaxed) }

    func privateHandle(for field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldHandle?> {
        calls.wrappingAdd(1, ordering: .relaxed)
        guard !focusMoved.load(ordering: .relaxed) else { return .success(nil) }
        return .success(FieldHandle(pid: field.pid, token: field.token + Self.privateOffset, element: nil))
    }
}

private struct ReadbackRig {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let capture: CaptureController
    let field: SimulatedTextField
    let access: FakeFocusedFieldAccess
    let elements: ElementTimeoutFieldAccess
    let resolver = FakeReadbackFieldResolver()
    /// The injection queue has no queued or in-flight job.
    let idle = Atomic<Bool>(true)
    let focus: SnapshotCell<FocusSnapshot>
    let secure: SnapshotCell<SecureInputSnapshot>
    let readback: DevReadback

    init(text: String, focus snapshot: FocusSnapshot = ReadbackRig.focus()) throws {
        scheduler = ManualScheduler(clock: clock)
        capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
            fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock, scheduler: scheduler)
        try capture.dev.start(appVersion: "test")
        field = SimulatedTextField(text: text)
        access = FakeFocusedFieldAccess(field: field)
        elements = ElementTimeoutFieldAccess(base: access)
        let epoch = ReaderEpoch()
        focus = SnapshotCell(snapshot, epoch: epoch)
        secure = SnapshotCell(.initial, epoch: epoch)
        let focusCell = focus
        let secureCell = secure
        let idleFlag = idle
        readback = DevReadback(
            recorder: capture.dev, fieldAccess: elements, fieldResolver: resolver,
            isInjectionIdle: { idleFlag.load(ordering: .relaxed) }, focus: { focusCell.load() },
            secureInput: { secureCell.load() }, clock: clock, scheduler: scheduler)
    }

    /// A field KeyVi may read: `requireTextFocus: whenKnown`, AX available.
    static func focus(
        requireTextFocus: RequireTextFocus = .whenKnown, field: FieldContext = PipelineFixtures.field()
    ) -> FocusSnapshot {
        PipelineFixtures.focus(decision: PipelineFixtures.decision(requireTextFocus: requireTextFocus), field: field)
    }

    func advance(milliseconds: Int) { scheduler.advance(by: .milliseconds(milliseconds)) }

    /// A key or click goes down now (what the tap tells the recorder).
    func key() { capture.dev.noteInputDown(at: clock.now()) }

    /// An edit job finishes now (what the inject thread pushes).
    func jobFinished() {
        capture.dev.pushInject(
            .job(
                DevJobRecord(
                    sequence: 1, generation: 1, kind: "compose", strategy: .backspaceReplace, outcome: "executed",
                    deleteCount: 1, insertCount: 1, eventsPosted: 4, totalMicroseconds: 4_000, runMicroseconds: 2_000,
                    at: clock.now())))
    }

    /// Readback lines written so far (drains the recorder into its in-memory file).
    func readbackLines() -> [[String: Any]] {
        capture.dev.drain()
        let folder = URL(fileURLWithPath: "/logs/SampleApp/dev-traces", isDirectory: true)
        guard let files = try? capture.fileSystem.contentsOfDirectory(at: folder) else { return [] }
        return files.flatMap { url -> [[String: Any]] in
            let data = (try? capture.fileSystem.readData(at: url, maxBytes: 1 << 20)) ?? Data()
            return data.split(separator: 0x0A).compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    object["type"] as? String == "readback"
                else { return nil }
                return object
            }
        }
    }

    /// Readbacks written so far: reason, status and text.
    func readbacks() -> [(reason: String?, status: String?, text: String?)] {
        readbackLines().map { ($0["reason"] as? String, $0["status"] as? String, $0["text"] as? String) }
    }
}

@Suite struct DevReadbackTests {
    @Test func readsAtMostSixtyFourUnitsBeforeTheCaret() throws {
        let long = String(repeating: "x", count: 70) + "viết"
        let rig = try ReadbackRig(text: long)
        let record = rig.readback.read(.marker)
        #expect(record.status == .ok)
        #expect(record.textBeforeCaret == String(long.suffix(64)))
        #expect(record.selectionLocation == long.utf16.count && record.selectionLength == 0)
        #expect(record.bundle == PipelineFixtures.editorBundle.rawValue)
    }

    /// Observer rule: `electron.default` (`requireTextFocus: never`) is never read.
    @Test func neverReadsWhereTheRuleKeepsKeyViOffAccessibility() throws {
        let rig = try ReadbackRig(text: "abc", focus: ReadbackRig.focus(requireTextFocus: .never))
        #expect(rig.readback.read(.marker).status == .skippedRule)
        #expect(rig.access.callCount == 0)
    }

    @Test func neverReadsSecureFieldsOrUnderSecureInput() throws {
        let rig = try ReadbackRig(
            text: "abc", focus: ReadbackRig.focus(field: PipelineFixtures.field(secure: true)))
        #expect(rig.readback.read(.marker).status == .skippedSecure)
        rig.focus.publish(ReadbackRig.focus())
        rig.secure.publish(SecureInputSnapshot(generation: 1, enabled: true, holder: nil))
        #expect(rig.readback.read(.marker).status == .skippedSecure)
        #expect(rig.access.callCount == 0)
    }

    @Test func reportsTimeoutsAndUnavailableFields() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.access.setBehaviour(.timeout)
        #expect(rig.readback.read(.commit).status == .timedOut)
        rig.access.setBehaviour(.unavailable)
        #expect(rig.readback.read(.commit).status == .unavailable)
        rig.focus.publish(
            ReadbackRig.focus(
                field: FieldContext(
                    axAvailability: .unavailable, role: nil, subrole: nil, identifier: nil, domClasses: [],
                    editable: nil, secure: false)))
        rig.access.setBehaviour(.normal)
        let before = rig.access.callCount
        #expect(rig.readback.read(.commit).status == .unavailable)
        #expect(rig.access.callCount == before)
    }

    /// 1 s without a key, a click or a job: then one read for every trigger of the burst, the most specific reason,
    /// with how long it waited and how long the input had been idle.
    @Test func readsOnlyAfterOneSecondWithoutInput() throws {
        let rig = try ReadbackRig(text: "chào ")
        rig.key()
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 200)
        rig.key()
        rig.readback.handle([.backspaceEdit])
        rig.advance(milliseconds: 999)
        #expect(rig.readbacks().isEmpty)
        #expect(rig.resolver.callCount == 0)
        rig.advance(milliseconds: 1)
        let lines = rig.readbackLines()
        #expect(lines.count == 1)
        #expect(lines.first?["reason"] as? String == "backspaceEdit" && lines.first?["text"] as? String == "chào ")
        #expect(lines.first?["waitUs"] as? Int == 1_200_000)
        #expect(lines.first?["idleUs"] as? Int == 1_000_000)
        #expect(lines.first?["overlap"] == nil)
    }

    /// Incident 1 (Dokomo, 2026-11-14 22:41:30): the next word's first key went down 273 ms after the commit and
    /// 27 ms before the old 300 ms readback, and never reached the field. The read now waits until 1 s after that key.
    @Test func theNextWordsFirstKeyPostponesTheCommitReadback() throws {
        let rig = try ReadbackRig(text: "Khúc c")
        rig.key()  // the space that committed "Khúc"
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 273)
        rig.key()  // "c"
        rig.advance(milliseconds: 27)
        #expect(rig.resolver.callCount == 0 && rig.access.callCount == 0)
        rig.advance(milliseconds: 972)
        #expect(rig.readbacks().isEmpty)
        rig.advance(milliseconds: 1)
        #expect(rig.readbacks().map(\.text) == ["Khúc c"])
    }

    /// Typing without a 1 s pause postpones the read for as long as it lasts; the first pause reads once.
    @Test func continuousTypingPostponesTheReadUntilAPause() throws {
        let rig = try ReadbackRig(text: "abc")
        for index in 0..<50 {
            rig.key()
            if index % 5 == 4 { rig.readback.handle([.commit]) }
            rig.advance(milliseconds: 100)
        }
        #expect(rig.readbacks().isEmpty && rig.resolver.callCount == 0)
        rig.advance(milliseconds: 900)
        let lines = rig.readbackLines()
        #expect(lines.count == 1)
        #expect(lines.first?["waitUs"] as? Int == 5_500_000)
    }

    /// A marker waits for the pause too, then reads; with no recent input it reads at once.
    @Test func aMarkerWaitsForThePause() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.key()  // the chord itself goes down
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 999)
        #expect(rig.readbacks().isEmpty)
        rig.advance(milliseconds: 1)
        #expect(rig.readbacks().map(\.reason) == ["marker"])
        rig.advance(milliseconds: 5_000)
        rig.readback.handle([.marker])  // from the menu, long after the last key
        rig.advance(milliseconds: 0)
        #expect(rig.readbacks().count == 2)
    }

    /// Never more than one read per 300 ms, even for two menu markers in a row.
    @Test func readsAreAtLeastThreeHundredMillisecondsApart() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 0)
        #expect(rig.readbacks().count == 1)
        rig.advance(milliseconds: 100)
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 199)
        #expect(rig.readbacks().count == 1)
        rig.advance(milliseconds: 1)
        #expect(rig.readbacks().count == 2)
    }

    /// An edit job is activity: no read while one is queued or in flight, and none within 1 s after one finished.
    @Test func jobsPostponeTheReadLikeKeys() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.idle.store(false, ordering: .relaxed)
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 3_000)
        #expect(rig.access.callCount == 0 && rig.resolver.callCount == 0)
        rig.idle.store(true, ordering: .relaxed)
        rig.jobFinished()
        rig.advance(milliseconds: 999)
        #expect(rig.readbacks().isEmpty && rig.resolver.callCount == 0)
        rig.advance(milliseconds: 1_001)
        #expect(rig.readbacks().map(\.status) == ["ok"])
    }

    /// A key that goes down while the read is in flight is flagged on the line, so the scanner discounts the read.
    @Test func aKeyDuringTheReadIsFlagged() throws {
        let rig = try ReadbackRig(text: "abc")
        let capture = rig.capture
        let clock = rig.clock
        rig.elements.afterCall.withLock {
            $0 = .init { capture.dev.noteInputDown(at: clock.now()) }
        }
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 0)
        let line = try #require(rig.readbackLines().first)
        #expect(line["status"] as? String == "ok")
        #expect(line["overlap"] as? Bool == true)
        rig.elements.afterCall.withLock { $0 = nil }
        #expect(rig.readback.read(.marker).overlap == false)
    }

    /// The AX calls' duration is recorded (timeouts included); a read skipped before any AX call has none.
    @Test func theReadDurationIsRecorded() throws {
        let rig = try ReadbackRig(text: "abc")
        let clock = rig.clock
        rig.elements.afterCall.withLock { $0 = .init { clock.advance(byMicroseconds: 4_000) } }
        #expect(rig.readback.read(.commit).durationMicroseconds == 8_000)
        rig.access.setBehaviour(.timeout)
        let timedOut = rig.readback.read(.commit)
        #expect(timedOut.status == .timedOut && timedOut.durationMicroseconds == 4_000)
        rig.focus.publish(ReadbackRig.focus(requireTextFocus: .never))
        #expect(rig.readback.read(.commit).durationMicroseconds == nil)
        rig.access.setBehaviour(.normal)
        rig.focus.publish(ReadbackRig.focus())
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 0)
        #expect(rig.readbackLines().last?["durUs"] as? Int == 8_000)
    }

    /// The longest single AX call is recorded too: the scanner compares it with the inject worker's per-call
    /// timeout (`axCallTimeout`, PLT-R311 timing row), which the sum of up to three calls would overstate.
    @Test func theLongestAXCallIsRecorded() throws {
        let rig = try ReadbackRig(text: "abc")
        let clock = rig.clock
        let calls = Atomic<Int>(0)
        rig.elements.afterCall.withLock {
            $0 = .init {
                let index = calls.wrappingAdd(1, ordering: .relaxed).oldValue
                clock.advance(byMicroseconds: index == 0 ? 3_000 : 11_000)
            }
        }
        let record = rig.readback.read(.commit)
        #expect(record.durationMicroseconds == 14_000 && record.longestCallMicroseconds == 11_000)
        rig.elements.afterCall.withLock { $0 = nil }
        rig.focus.publish(ReadbackRig.focus(requireTextFocus: .never))
        #expect(rig.readback.read(.commit).longestCallMicroseconds == nil)
        rig.focus.publish(ReadbackRig.focus())
        rig.elements.afterCall.withLock { $0 = .init { clock.advance(byMicroseconds: 5_000) } }
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 0)
        #expect(rig.readbackLines().last?["maxCallUs"] as? Int == 5_000)
    }

    /// Review W8-E finding 1: the readback reads through its own element reference, so the timeout the worker set
    /// on the shared field element is never changed by a readback.
    @Test func readsThroughItsOwnElementAndLeavesTheWorkersTimeoutAlone() throws {
        let rig = try ReadbackRig(text: "chào")
        let shared = try #require(rig.focus.load().fieldHandle)
        _ = rig.elements.selectedRange(shared, timeout: .milliseconds(15))  // the worker's axSelection read
        let record = rig.readback.read(.marker)
        #expect(record.status == .ok && record.textBeforeCaret == "chào")
        #expect(rig.elements.timeouts[shared.token] == .milliseconds(15))
        let own = shared.token + FakeReadbackFieldResolver.privateOffset
        #expect(rig.elements.tokens.dropFirst().allSatisfy { $0 == own })
        #expect(rig.elements.timeouts[own] == DevReadback.axTimeout)
    }

    /// Focus moved since the snapshot (the app's focused element is another one): nothing is read.
    @Test func aMovedFocusSkipsTheRead() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.resolver.focusMoved.store(true, ordering: .relaxed)
        #expect(rig.readback.read(.marker).status == .skippedNoField)
        #expect(rig.access.callCount == 0)
    }

    /// A job pushed between the two reads stops the readback before its second call.
    @Test func aJobStartingMidReadStopsTheRead() throws {
        let rig = try ReadbackRig(text: "abc")
        let idle = rig.idle
        rig.elements.afterCall.withLock { $0 = .init { idle.store(false, ordering: .relaxed) } }
        let record = rig.readback.read(.commit)
        #expect(record.status == .skippedBusy && record.textBeforeCaret == nil)
        #expect(rig.access.callCount == 1)
    }

    /// Nothing is read while the recorder is paused.
    @Test func aPausedRecorderReadsNothing() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.capture.dev.pause()
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 10)
        #expect(rig.access.callCount == 0)
    }
}
#endif
