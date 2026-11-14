// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007) field readback: at most 64 UTF-16 units before the caret and the selection; 300 ms after a
// Backspace edit or a commit, debounced to one read per 300 ms, at once for a marker. Observer rule: no read where
// the compat rule keeps KeyVi off accessibility (`requireTextFocus: never`), never in a secure field or while
// secure input is on, and only reads (no writes, no AXEnhancedUserInterface or AXManualAccessibility).

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

    /// Readbacks written so far (drains the recorder into its in-memory file).
    func readbacks() -> [(reason: String?, status: String?, text: String?)] {
        capture.dev.drain()
        let folder = URL(fileURLWithPath: "/logs/SampleApp/dev-traces", isDirectory: true)
        guard let files = try? capture.fileSystem.contentsOfDirectory(at: folder) else { return [] }
        return files.flatMap { url -> [(reason: String?, status: String?, text: String?)] in
            let data = (try? capture.fileSystem.readData(at: url, maxBytes: 1 << 20)) ?? Data()
            return data.split(separator: 0x0A).compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    object["type"] as? String == "readback"
                else { return nil }
                return (object["reason"] as? String, object["status"] as? String, object["text"] as? String)
            }
        }
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

    /// 300 ms after the last trigger, one read for a burst, the most specific reason.
    @Test func readsThreeHundredMillisecondsAfterABurst() throws {
        let rig = try ReadbackRig(text: "chào")
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 200)
        rig.readback.handle([.backspaceEdit])
        rig.advance(milliseconds: 299)
        #expect(rig.readbacks().isEmpty)
        rig.advance(milliseconds: 1)
        let reads = rig.readbacks()
        #expect(reads.count == 1)
        #expect(reads.first?.reason == "backspaceEdit" && reads.first?.text == "chào")
    }

    /// A marker reads at once, but never sooner than 300 ms after the previous read.
    @Test func aMarkerReadsAtOnceWithinTheRateLimit() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 0)
        #expect(rig.readbacks().map(\.reason) == ["marker"])
        rig.advance(milliseconds: 100)
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 199)
        #expect(rig.readbacks().count == 1)
        rig.advance(milliseconds: 1)
        #expect(rig.readbacks().count == 2)
    }

    /// Continuous typing never postpones a read by more than 1 s.
    @Test func triggersNeverWaitMoreThanOneSecond() throws {
        let rig = try ReadbackRig(text: "abc")
        var elapsed = 0
        while elapsed < 1_000 {
            rig.readback.handle([.commit])
            rig.advance(milliseconds: 100)
            elapsed += 100
        }
        #expect(rig.readbacks().count == 1)
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

    /// No readback call while an edit job is queued or in flight: the read waits, 20 ms at a time.
    @Test func waitsWhileAJobIsInFlight() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.idle.store(false, ordering: .relaxed)
        rig.readback.handle([.commit])
        rig.advance(milliseconds: 600)
        #expect(rig.access.callCount == 0 && rig.resolver.callCount == 0)
        #expect(rig.readbacks().isEmpty)
        rig.idle.store(true, ordering: .relaxed)
        rig.advance(milliseconds: 20)
        #expect(rig.readbacks().map(\.status) == ["ok"])
    }

    /// A worker busy for the whole second: the read is recorded as skipped, without an AX call.
    @Test func aWorkerBusyForOneSecondSkipsTheRead() throws {
        let rig = try ReadbackRig(text: "abc")
        rig.idle.store(false, ordering: .relaxed)
        rig.readback.handle([.marker])
        rig.advance(milliseconds: 1_100)
        #expect(rig.readbacks().map(\.status) == ["skippedBusy"])
        #expect(rig.access.callCount == 0 && rig.resolver.callCount == 0)
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
