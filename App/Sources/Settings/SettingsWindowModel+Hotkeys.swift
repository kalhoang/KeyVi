// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hotkey recorder of the Settings window (PRD-R15, PRD-R16, PRD-R18). The capture lifecycle (key monitor, tap
// hotkey suspension, ADR 0305) lives in ShellCore's HotkeyCaptureController; this file adapts it to the views and
// supplies the NSEvent local monitor.

import AppKit
import AppModel
import InputHost
import ShellCore

extension SettingsWindowModel {
    var recorder: HotkeyRecorderSession? { capture.session }

    /// The role being recorded right now (a finished or rejected session stays on screen but is not recording).
    var recordingRole: HotkeyRole? { capture.recordingRole }

    /// Line under the recorder: live keys, a rejection reason or the PRD-R16 conflict warning.
    func recorderStatus(for role: HotkeyRole) -> String? {
        guard let recorder, recorder.role == role else { return conflictWarning(for: role) }
        return HotkeyRecorderText.status(recorder.state, role: role, appName: appName, localizer: localizer)
    }

    /// PRD-R16: a saved binding that macOS also uses keeps its warning while it is in use. Cached per store state.
    func conflictWarning(for role: HotkeyRole) -> String? {
        capture.savedConflict(for: role).map {
            HotkeyRecorderText.conflictMessage($0, appName: appName, localizer: localizer)
        }
    }

    var conflictHelpURL: URL? { HotkeyRecorderText.helpURL(siteHost: brand.siteHost, localizer: localizer) }

    func hasConflict(for role: HotkeyRole) -> Bool {
        if let recorder, recorder.role == role, case .finished(_, _?) = recorder.state { return true }
        return capture.savedConflict(for: role) != nil
    }

    func startRecording(_ role: HotkeyRole) { capture.start(role) }

    func cancelRecording() { capture.cancel() }

    /// The window resigned key (another app or window took the keyboard): stop swallowing its keys.
    func interruptRecording() { capture.interrupt() }

    func useDefaultToggle() {
        cancelRecording()
        edit(.toggleHotkey(.defaultToggle))
    }

    /// PRD-R18: Escape is the suggested restore key; "Không dùng" stores an explicit none (D8).
    func setRestoreHotkey(_ binding: HotkeyBinding?) {
        cancelRecording()
        edit(.restoreHotkey(binding))
    }

    func saveRecorded(_ binding: HotkeyBinding, for role: HotkeyRole) {
        edit(role == .toggleMode ? .toggleHotkey(binding) : .restoreHotkey(binding))
    }

    func refreshSavedConflicts() {
        capture.refreshSavedConflicts(toggle: settings.toggleHotkey, restore: settings.restoreHotkey)
    }
}

/// While recording, takes every key event of the app's windows so none reaches a button or field (ADR 0305).
@MainActor
final class LocalKeyMonitor: RecorderKeyMonitoring {
    private var token: Any?

    func install(_ handler: @escaping @MainActor (RecorderKeyEvent) -> Void) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated {
                if let input = Self.recorderEvent(event) { handler(input) }
            }
            return nil
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
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
