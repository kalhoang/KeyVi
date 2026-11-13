// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Capture lifecycle of the Settings hotkey recorder (ADR 0305, PRD-R14, PRD-R67). While a recording is visible
// and the window is key, a key monitor takes the window's key events and the tap's hotkeys are suspended. Any way
// out (finished, rejected, cancelled, pane switched, window resigned key or closed, controller released) removes
// the monitor and gives the hotkeys back exactly once, so a hidden recorder never swallows typing.

public import AppModel
public import InputHost
public import Observation

/// Installs and removes the window's key-event monitor (`NSEvent` local monitor in the app, a fake in tests).
@MainActor
public protocol RecorderKeyMonitoring: AnyObject {
    func install(_ handler: @escaping @MainActor (RecorderKeyEvent) -> Void)
    func remove()
}

@MainActor
@Observable
public final class HotkeyCaptureController {
    /// The session on screen: recording, or finished / rejected and kept for its status line.
    public private(set) var session: HotkeyRecorderSession?
    public private(set) var isCapturing = false
    private var savedConflicts: [HotkeyRole: SystemShortcutConflict] = [:]

    @ObservationIgnored private let monitor: any RecorderKeyMonitoring
    @ObservationIgnored private let setHotkeysSuspended: @MainActor (Bool) -> Void
    @ObservationIgnored private let onFinished: @MainActor (HotkeyRole, HotkeyBinding) -> Void
    @ObservationIgnored private let readLayout: @MainActor () -> LayoutTable?

    /// - Parameters:
    ///   - setHotkeysSuspended: `InputHostController.setRecorderActive(_:)` through the composition root.
    ///   - onFinished: saves the recorded binding (conflicts are saved with a warning, PRD-R16).
    ///   - readLayout: current layout table; read once per recording and once per saved-state change, never per
    ///     render (TIS calls stay out of SwiftUI bodies).
    public init(
        monitor: any RecorderKeyMonitoring, setHotkeysSuspended: @escaping @MainActor (Bool) -> Void,
        onFinished: @escaping @MainActor (HotkeyRole, HotkeyBinding) -> Void,
        readLayout: @escaping @MainActor () -> LayoutTable? = { nil }
    ) {
        self.monitor = monitor
        self.setHotkeysSuspended = setHotkeysSuspended
        self.onFinished = onFinished
        self.readLayout = readLayout
    }

    isolated deinit {
        if isCapturing { endCapture() }
    }

    /// The role being recorded right now (a finished or rejected session stays on screen but is not recording).
    public var recordingRole: HotkeyRole? { isCapturing ? session?.role : nil }

    public func start(_ role: HotkeyRole) {
        cancel()
        session = HotkeyRecorderSession(role: role, layout: readLayout())
        isCapturing = true
        setHotkeysSuspended(true)
        monitor.install { [weak self] event in self?.feed(event) }
    }

    /// "Hủy", a pane switch or the window closing: ends the capture and clears the session.
    public func cancel() {
        if isCapturing { endCapture() }
        session = nil
    }

    /// The window resigned key: an active recording is dropped, a finished or rejected result stays on screen.
    public func interrupt() {
        guard isCapturing else { return }
        cancel()
    }

    /// PRD-R16 conflict of a saved binding, as of the last `refreshSavedConflicts`.
    public func savedConflict(for role: HotkeyRole) -> SystemShortcutConflict? { savedConflicts[role] }

    /// Recomputes the saved bindings' conflicts with one layout read (on show and on every new store state).
    public func refreshSavedConflicts(toggle: HotkeyBinding, restore: HotkeyBinding?) {
        let layout = readLayout()
        var conflicts: [HotkeyRole: SystemShortcutConflict] = [:]
        conflicts[.toggleMode] = HotkeyRecorder.conflict(for: toggle, layout: layout)
        conflicts[.restoreLastWord] = restore.flatMap { HotkeyRecorder.conflict(for: $0, layout: layout) }
        if conflicts != savedConflicts { savedConflicts = conflicts }
    }

    private func feed(_ event: RecorderKeyEvent) {
        guard isCapturing, var current = session else { return }
        let state = current.handle(event)
        session = current
        switch state {
        case .finished(let binding, _):
            endCapture()
            onFinished(current.role, binding)
        case .rejected:
            endCapture()
        case .idle, .recording:
            break
        }
    }

    private func endCapture() {
        monitor.remove()
        isCapturing = false
        setHotkeysSuspended(false)
    }
}
