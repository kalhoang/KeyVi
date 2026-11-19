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

    /// ENG-R1119, plan Task 24: the focus line carries the variant's restore key (`rhk`, the rule's
    /// `features.restoreHotkey`), which replay needs to rebuild the typo correction switch the host passed.
    @Test func aFocusRecordCarriesTheRulesRestoreKey() {
        var decision = HostDecisionMapper.map(FocusFixtures.decision(nil), engine: .native, optedIntoPaste: false)
        for restoreHotkey in [true, false] {
            decision.variant.restoreHotkey = restoreHotkey
            let snapshot = FocusSnapshot(
                generation: .initial, app: nil, field: .unknown, decision: decision, mode: .vietnamese,
                modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero, pause: nil)
            let record = DevFocusRecord(snapshot, at: .zero)
            #expect(record.restoreHotkey == restoreHotkey)
            #expect(DevTraceLine(.focus(record), t: 0).rhk == restoreHotkey)
        }
    }

    /// 685 key downs of 15/11/2026 went to an app AX did not name: the focus line then carries NSWorkspace's
    /// frontmost application (format version 3), and only then.
    @Test func aFocusWithoutAnAppNamesTheFrontmostApplication() throws {
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
            fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
            scheduler: ManualScheduler(clock: clock))
        try capture.dev.start(appVersion: "test")
        let thread = RunLoopThread(name: "test.focus.dev.frontmost", qualityOfService: .userInitiated)
        thread.start()
        defer { thread.stop() }
        let ax = FakeAXProvider()
        let processes = FakeProcessIdentityProvider(processes: FocusFixtures.processes)
        processes.setFrontmost(FocusFixtures.zaloPID)
        let initial = FocusSnapshot(
            generation: .initial, app: nil, field: .unknown,
            decision: HostDecisionMapper.map(FocusFixtures.decision(nil), engine: .native, optedIntoPaste: false),
            mode: .vietnamese, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero,
            pause: nil)
        let tracker = FocusTracker(
            thread: thread, ax: ax, processes: processes,
            output: SnapshotCell(initial, epoch: ReaderEpoch()), generation: CurrentFocusGeneration(),
            inbox: SPSCRing<AXNotice>(capacity: 64), metrics: PlatformMetrics(), health: HealthEventLog(),
            clock: clock, macOSVersion: LooseVersion("27.2")!, capture: capture)
        tracker.start(
            rules: FocusFixtures.resolver([:]),
            memory: AppModeMemory(document: AppModesDocument(), rememberPerApp: true, firstSeen: .inherit))
        tracker.waitUntilIdle()
        ax.focus(pid: FocusFixtures.zaloPID, attributes: FocusFixtures.attributes(role: "AXTextArea"), notify: nil)
        tracker.revalidate()
        tracker.waitUntilIdle()
        ax.clearFocusedApplication()
        tracker.revalidate()
        tracker.waitUntilIdle()
        tracker.stop()
        tracker.waitUntilIdle()
        var focus: [DevFocusRecord] = []
        while let record = capture.dev.focusRecords.pop() {
            if case .focus(let value) = record { focus.append(value) }
        }
        let named = try #require(focus.first { $0.bundle != nil })
        let unnamed = try #require(focus.last)
        #expect(named.frontmost == nil)
        #expect(unnamed.bundle == nil && unnamed.frontmost == FocusFixtures.zalo.rawValue)
    }

    /// PLT-R381 amendment: a snapshot whose app was taken from the frontmost application is written like a focus line
    /// AX could not name (format version 3: no `bundle`, the app in `front`), with the bundle-level rule it resolved
    /// to, so the scanner keeps attributing it in parentheses.
    @Test func aFrontmostFallbackSnapshotIsWrittenAsTheFrontmostApplication() {
        var snapshot = FocusSnapshot(
            generation: FocusGeneration(rawValue: 4),
            app: FocusedApp(
                pid: FocusFixtures.codePID, bundle: FocusFixtures.code, appVersion: nil, engine: .electron,
                source: .frontmostApplication),
            field: FieldContext(
                axAvailability: .available, role: nil, subrole: nil, identifier: nil, domClasses: [], editable: nil,
                secure: false),
            decision: HostDecisionMapper.map(
                FocusFixtures.decision("editor.sample", engine: .electron), engine: .electron, optedIntoPaste: false),
            mode: .vietnamese, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero,
            pause: nil)
        let fallback = DevFocusRecord(snapshot, at: .zero)
        #expect(fallback.bundle == nil && fallback.frontmost == FocusFixtures.code.rawValue)
        #expect(fallback.rule == "editor.sample")
        snapshot.app?.source = .accessibility
        let named = DevFocusRecord(snapshot, frontmost: "com.example.other", at: .zero)
        #expect(named.bundle == FocusFixtures.code.rawValue && named.frontmost == nil)
    }

    /// Review W14-P finding 1: when AX starts naming the app that was taken from the frontmost application (no
    /// element either way), the snapshot is relabelled without a new generation, and the focus line follows, so the
    /// trace does not keep writing the app as `front`.
    @Test func aRelabelledFallbackAppIsRecordedAgain() throws {
        let clock = ManualClock()
        let capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/SampleApp/captures", isDirectory: true),
            fileSystem: InMemoryFileSystem(), wallClock: FixedWallClock(), clock: clock,
            scheduler: ManualScheduler(clock: clock))
        try capture.dev.start(appVersion: "test")
        let thread = RunLoopThread(name: "test.focus.dev.relabel", qualityOfService: .userInitiated)
        thread.start()
        defer { thread.stop() }
        let ax = FakeAXProvider()
        let processes = FakeProcessIdentityProvider(processes: FocusFixtures.processes)
        processes.setFrontmost(FocusFixtures.zaloPID)
        ax.clearFocusedApplication()
        let initial = FocusSnapshot(
            generation: .initial, app: nil, field: .unknown,
            decision: HostDecisionMapper.map(FocusFixtures.decision(nil), engine: .native, optedIntoPaste: false),
            mode: .vietnamese, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero,
            pause: nil)
        let tracker = FocusTracker(
            thread: thread, ax: ax, processes: processes,
            output: SnapshotCell(initial, epoch: ReaderEpoch()), generation: CurrentFocusGeneration(),
            inbox: SPSCRing<AXNotice>(capacity: 64), metrics: PlatformMetrics(), health: HealthEventLog(),
            clock: clock, macOSVersion: LooseVersion("27.2")!, capture: capture)
        tracker.start(
            rules: FocusFixtures.resolver([:]),
            memory: AppModeMemory(document: AppModesDocument(), rememberPerApp: true, firstSeen: .inherit))
        tracker.waitUntilIdle()
        ax.focusWithoutElement(pid: FocusFixtures.zaloPID, notify: nil)
        tracker.revalidate()
        tracker.waitUntilIdle()
        tracker.stop()
        tracker.waitUntilIdle()
        var focus: [DevFocusRecord] = []
        while let record = capture.dev.focusRecords.pop() {
            if case .focus(let value) = record { focus.append(value) }
        }
        let fallback = try #require(focus.first)
        let named = try #require(focus.last)
        #expect(fallback.bundle == nil && fallback.frontmost == FocusFixtures.zalo.rawValue)
        #expect(named.bundle == FocusFixtures.zalo.rawValue && named.frontmost == nil)
        #expect(named.generation == fallback.generation)
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
