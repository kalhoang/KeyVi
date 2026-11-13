// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capture lifecycle of the Settings hotkey recorder (ADR 0305, PRD-R14, PRD-R67): the window's key monitor and the
// tap's hotkey suspension exist only while a recording is visible and the window is key. Switching pane, the window
// resigning key, closing it or releasing the controller ends the capture and gives the hotkeys back.

import AppModel
import InputHost
import Testing

@testable import ShellCore

@MainActor
final class FakeKeyMonitor: RecorderKeyMonitoring {
    private(set) var handler: (@MainActor (RecorderKeyEvent) -> Void)?
    private(set) var installs = 0
    private(set) var removals = 0

    var isInstalled: Bool { handler != nil }

    func install(_ handler: @escaping @MainActor (RecorderKeyEvent) -> Void) {
        installs += 1
        self.handler = handler
    }

    func remove() {
        removals += 1
        handler = nil
    }

    func send(_ event: RecorderKeyEvent) { handler?(event) }
}

@MainActor
final class SuspensionLog {
    private(set) var calls: [Bool] = []
    var suspended: Bool { calls.last ?? false }
    func record(_ value: Bool) { calls.append(value) }
}

@MainActor
@Suite struct HotkeyCaptureTests {
    typealias Flags = HotkeyRecorderSession.Flags
    let monitor = FakeKeyMonitor()
    let log = SuspensionLog()

    func makeCapture(onFinished: @escaping @MainActor (HotkeyRole, HotkeyBinding) -> Void = { _, _ in })
        -> HotkeyCaptureController
    {
        let log = log
        return HotkeyCaptureController(
            monitor: monitor, setHotkeysSuspended: { log.record($0) }, onFinished: onFinished)
    }

    func sendControlShiftTap() {
        monitor.send(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control))
        monitor.send(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.control | Flags.shift))
        monitor.send(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.control))
        monitor.send(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: 0))
    }

    @Test func startInstallsTheMonitorAndSuspendsTheTapHotkeys_ADR0305() {
        let capture = makeCapture()
        capture.start(.toggleMode)
        #expect(monitor.isInstalled)
        #expect(log.calls == [true])
        #expect(capture.isCapturing)
        #expect(capture.recordingRole == .toggleMode)
    }

    @Test func finishedRecordingSavesStopsCapturingAndKeepsTheResultOnScreen() {
        var saved: [(HotkeyRole, HotkeyBinding)] = []
        let capture = makeCapture { saved.append(($0, $1)) }
        capture.start(.toggleMode)
        sendControlShiftTap()
        #expect(saved.count == 1)
        #expect(saved.first?.0 == .toggleMode)
        #expect(saved.first?.1 == .modifierTap(.controlShift))
        #expect(!monitor.isInstalled)
        #expect(log.calls == [true, false])
        #expect(capture.recordingRole == nil)
        #expect(capture.session?.state == .finished(.modifierTap(.controlShift), conflict: nil))
    }

    @Test func rejectedRecordingStopsCapturingWithoutSaving() {
        var saved = 0
        let capture = makeCapture { _, _ in saved += 1 }
        capture.start(.toggleMode)
        monitor.send(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: Flags.shift))
        monitor.send(.flagsChanged(keyCode: KeyCode.shift.rawValue, flags: 0))
        #expect(saved == 0)
        #expect(!monitor.isInstalled)
        #expect(log.suspended == false)
        #expect(capture.session?.state == .rejected(.unsupportedModifierTap))
    }

    @Test func windowResigningKeyEndsAnActiveRecording_PRDR67() {
        // "Đổi", then click another app: keys typed later must reach their field and the toggle must work again.
        let capture = makeCapture()
        capture.start(.toggleMode)
        monitor.send(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control))
        capture.interrupt()
        #expect(!monitor.isInstalled)
        #expect(log.calls == [true, false])
        #expect(capture.session == nil)
        #expect(!capture.isCapturing)
    }

    @Test func interruptKeepsAFinishedResultAndDoesNotResumeTwice() {
        let capture = makeCapture()
        capture.start(.toggleMode)
        sendControlShiftTap()
        capture.interrupt()
        #expect(capture.session?.finishedBinding == .modifierTap(.controlShift))
        #expect(log.calls == [true, false])
        #expect(monitor.removals == 1)
    }

    @Test func cancelClearsEverythingAndIsIdempotent() {
        let capture = makeCapture()
        capture.cancel()
        #expect(log.calls.isEmpty)
        #expect(monitor.removals == 0)
        capture.start(.restoreLastWord)
        capture.cancel()
        capture.cancel()
        #expect(log.calls == [true, false])
        #expect(monitor.removals == 1)
        #expect(capture.session == nil)
    }

    @Test func restartingReplacesTheSessionWithOneMonitorAndBalancedSuspension() {
        let capture = makeCapture()
        capture.start(.toggleMode)
        capture.start(.restoreLastWord)
        #expect(capture.recordingRole == .restoreLastWord)
        #expect(monitor.installs == 2)
        #expect(monitor.removals == 1)
        #expect(log.calls == [true, false, true])
        capture.cancel()
        #expect(log.suspended == false)
    }

    @Test func eventsAfterTheCaptureEndedAreIgnored() {
        var saved = 0
        let capture = makeCapture { _, _ in saved += 1 }
        capture.start(.toggleMode)
        let staleHandler = monitor.handler
        capture.cancel()
        staleHandler?(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control))
        #expect(capture.session == nil)
        #expect(saved == 0)
    }

    @Test func releasingTheControllerWhileRecordingRemovesTheMonitorAndResumesHotkeys() {
        var capture: HotkeyCaptureController? = makeCapture()
        capture?.start(.toggleMode)
        capture = nil
        #expect(!monitor.isInstalled)
        #expect(log.calls == [true, false])
    }

    @Test func layoutIsReadOncePerRecordingNotPerRender() {
        var reads = 0
        let capture = HotkeyCaptureController(
            monitor: monitor, setHotkeysSuspended: { _ in }, onFinished: { _, _ in },
            readLayout: {
                reads += 1
                return nil
            })
        capture.start(.toggleMode)
        monitor.send(.flagsChanged(keyCode: KeyCode.control.rawValue, flags: Flags.control))
        _ = capture.recordingRole
        _ = capture.session
        #expect(reads == 1)
    }
}

@MainActor
@Suite struct SavedHotkeyConflictTests {
    @Test func savedBindingConflictsAreComputedOnceWhenTheStateChanges_PRDR16() {
        var reads = 0
        let capture = HotkeyCaptureController(
            monitor: FakeKeyMonitor(), setHotkeysSuspended: { _ in }, onFinished: { _, _ in },
            readLayout: {
                reads += 1
                return nil
            })
        capture.refreshSavedConflicts(
            toggle: .keyCombo(modifiers: [.control], keyCode: .space), restore: .key(.escape))
        #expect(reads == 1)
        for _ in 0..<5 {
            #expect(capture.savedConflict(for: .toggleMode) == .selectPreviousInputSource)
            #expect(capture.savedConflict(for: .restoreLastWord) == nil)
        }
        #expect(reads == 1)
        capture.refreshSavedConflicts(toggle: .modifierTap(.controlShift), restore: nil)
        #expect(capture.savedConflict(for: .toggleMode) == nil)
        #expect(reads == 2)
    }
}
