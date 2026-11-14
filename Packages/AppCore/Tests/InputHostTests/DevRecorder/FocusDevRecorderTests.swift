// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): every focus change goes to the dev recorder with the bundle ID, role, subrole, the compat
// rule and the decision it resolved to, and the mode with its source. Never window titles or URLs.

#if DEV_RECORDER
import AppModel
import CompatRules
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Testing

@testable import Diagnostics
@testable import InputHost
@testable import TestSupport

@Suite struct FocusDevRecorderTests {
    @Test func focusChangesCarryTheRuleAndTheDecision() throws {
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
            fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
            scheduler: ManualScheduler(clock: clock))
        try capture.dev.start(appVersion: "test")
        let thread = RunLoopThread(name: "test.focus.dev", qualityOfService: .userInitiated)
        thread.start()
        defer { thread.stop() }
        let ax = FakeAXProvider()
        let initial = FocusSnapshot(
            generation: .initial, app: nil, field: .unknown,
            decision: HostDecisionMapper.map(FocusFixtures.decision(nil), engine: .native, optedIntoPaste: false),
            mode: .vietnamese, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero,
            pause: nil)
        let tracker = FocusTracker(
            thread: thread, ax: ax, processes: FakeProcessIdentityProvider(processes: FocusFixtures.processes),
            output: SnapshotCell(initial, epoch: ReaderEpoch()), generation: CurrentFocusGeneration(),
            inbox: SPSCRing<AXNotice>(capacity: 64), metrics: PlatformMetrics(), health: HealthEventLog(),
            clock: clock, macOSVersion: LooseVersion("27.2")!, capture: capture)
        let rules = FocusFixtures.resolver([FocusFixtures.zalo: FocusFixtures.decision("chat.sample")])
        tracker.start(
            rules: rules,
            memory: AppModeMemory(document: AppModesDocument(), rememberPerApp: true, firstSeen: .inherit))
        tracker.waitUntilIdle()
        ax.focus(
            pid: FocusFixtures.zaloPID,
            attributes: FocusFixtures.attributes(
                role: "AXTextArea", title: "Secret chat", url: "https://example.com/x"),
            notify: nil)
        tracker.revalidate()
        tracker.waitUntilIdle()
        tracker.stop()
        tracker.waitUntilIdle()
        var focus: [DevFocusRecord] = []
        while let record = capture.dev.focusRecords.pop() {
            if case .focus(let value) = record { focus.append(value) }
        }
        let last = try #require(focus.last)
        #expect(last.bundle == FocusFixtures.zalo.rawValue && last.role == "AXTextArea")
        #expect(last.rule == "chat.sample" && last.strategy == "backspaceReplace")
        #expect(TypingMode(rawValue: last.mode) != nil && !last.secure && !last.modeSource.isEmpty)
        // The record type has no title or URL; its text fields never carry them.
        let text = [last.bundle, last.role, last.subrole, last.rule, last.modeSource].compactMap { $0 }.joined()
        #expect(!text.contains("Secret") && !text.contains("example.com/x"))
    }

    /// Review W8-E finding 3: focus moves from a password field to a normal one while the secure gap is still open
    /// (the ax thread publishes before the main thread ends the gap); the normal field's focus line is written.
    @MainActor @Test func theFieldFocusedWhenASecureGapEndsIsRecorded() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true), fileSystem: fileSystem,
            wallClock: FixedWallClock(), clock: clock, scheduler: ManualScheduler(clock: clock))
        let rig = HostRig(capture: capture)
        await rig.start()
        defer { rig.stop() }
        try capture.dev.start(appVersion: "test")
        rig.controller.startDevReadback(queue: DispatchQueue(label: "test.dev.attention"))
        rig.ax.focus(
            pid: HostRig.editorPID, attributes: Self.attributes(role: "AXTextField", subrole: "AXSecureTextField"),
            notify: .focusedElementChanged)
        rig.settle()
        #expect(!capture.dev.isActive)
        rig.ax.focus(
            pid: HostRig.editorPID, attributes: Self.attributes(role: "AXTextArea", subrole: nil),
            notify: .focusedElementChanged)
        rig.settle()
        #expect(capture.dev.isActive)
        capture.dev.drain()
        let folder = URL(fileURLWithPath: "/logs/SampleApp/dev-traces", isDirectory: true)
        let lines = try fileSystem.contentsOfDirectory(at: folder).flatMap { url in
            try fileSystem.readData(at: url, maxBytes: 1 << 20).split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(DevTraceLine.self, from: Data($0))
            }
        }
        let gap = try #require(lines.lastIndex { $0.type == .gap })
        #expect(lines[gap...].contains { $0.type == .focus && $0.role == "AXTextArea" })
    }

    private static func attributes(role: String, subrole: String?) -> FocusAttributes {
        FocusAttributes(
            role: role, subrole: subrole, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
            documentURL: nil, windowTitle: nil)
    }
}
#endif
