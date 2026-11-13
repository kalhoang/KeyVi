// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Hotkey recorder of the Settings window (PRD-R15, PRD-R16, PRD-R18). While recording, a local event monitor
// takes the window's key events (they never reach a button) and the tap's hotkeys are suspended (ADR 0305).

import AppKit
import AppModel
import InputHost
import ShellCore

extension SettingsWindowModel {
    /// The role being recorded right now (a finished or rejected session stays on screen but is not recording).
    var recordingRole: HotkeyRole? {
        guard let recorder else { return nil }
        switch recorder.state {
        case .idle, .recording: return recorder.role
        case .finished, .rejected: return nil
        }
    }

    /// Line under the recorder: live keys, a rejection reason or the PRD-R16 conflict warning.
    func recorderStatus(for role: HotkeyRole) -> String? {
        guard let recorder, recorder.role == role else { return conflictWarning(for: role) }
        return HotkeyRecorderText.status(recorder.state, role: role, appName: appName, localizer: localizer)
    }

    /// PRD-R16: a saved binding that macOS also uses keeps its warning while it is in use.
    func conflictWarning(for role: HotkeyRole) -> String? {
        let binding = role == .toggleMode ? settings.toggleHotkey : settings.restoreHotkey
        guard let binding, let conflict = HotkeyRecorder.conflict(for: binding, layout: readLayout()) else {
            return nil
        }
        return HotkeyRecorderText.conflictMessage(conflict, appName: appName, localizer: localizer)
    }

    var conflictHelpURL: URL? { HotkeyRecorderText.helpURL(siteHost: brand.siteHost, localizer: localizer) }

    func hasConflict(for role: HotkeyRole) -> Bool {
        if let recorder, recorder.role == role, case .finished(_, _?) = recorder.state { return true }
        return conflictWarning(for: role) != nil
    }

    func startRecording(_ role: HotkeyRole) {
        cancelRecording()
        recorder = HotkeyRecorderSession(role: role, layout: readLayout())
        actions?.setHotkeyRecorderActive(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func cancelRecording() {
        let wasCapturing = keyMonitor != nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recorder = nil
        if wasCapturing { actions?.setHotkeyRecorderActive(false) }
    }

    func useDefaultToggle() {
        cancelRecording()
        edit(.toggleHotkey(.defaultToggle))
    }

    /// PRD-R18: Escape is the suggested restore key; "Không dùng" stores an explicit none (D8).
    func setRestoreHotkey(_ binding: HotkeyBinding?) {
        cancelRecording()
        edit(.restoreHotkey(binding))
    }

    private func record(_ event: NSEvent) {
        guard var session = recorder, let input = Self.recorderEvent(event) else { return }
        let state = session.handle(input)
        recorder = session
        switch state {
        case .finished(let binding, _):
            let role = session.role
            stopMonitoring()
            edit(role == .toggleMode ? .toggleHotkey(binding) : .restoreHotkey(binding))
        case .rejected:
            stopMonitoring()
        case .idle, .recording:
            break
        }
    }

    /// Ends capturing but keeps the finished state on screen (warning or rejection reason).
    private func stopMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        actions?.setHotkeyRecorderActive(false)
    }

    static func recorderEvent(_ event: NSEvent) -> RecorderKeyEvent? {
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged: return .flagsChanged(keyCode: event.keyCode, flags: flags)
        case .keyDown: return .keyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
        case .keyUp: return .keyUp(keyCode: event.keyCode)
        default: return nil
        }
    }
}
