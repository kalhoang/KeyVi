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

private struct ReadbackRig {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let capture: CaptureController
    let field: SimulatedTextField
    let access: FakeFocusedFieldAccess
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
        let epoch = ReaderEpoch()
        focus = SnapshotCell(snapshot, epoch: epoch)
        secure = SnapshotCell(.initial, epoch: epoch)
        let focusCell = focus
        let secureCell = secure
        readback = DevReadback(
            recorder: capture.dev, fieldAccess: access, focus: { focusCell.load() },
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
