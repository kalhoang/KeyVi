// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): every focus change goes to the dev recorder with the bundle ID, role, subrole, the compat
// rule and the decision it resolved to, and the mode with its source. Never window titles or URLs.

#if DEV_RECORDER
import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Testing

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
}
#endif
