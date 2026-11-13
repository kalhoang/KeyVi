// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Hotkey recogniser (PRD-R14, PRD-R15, PRD-R18, PLT-R310 step 5) and recorder (PRD-R15, PRD-R16). Pure value
// types: the recogniser lives on the tap thread inside the pipeline, the recorder in the settings UI.

public import AppModel
public import RealtimeSupport

public enum HotkeyInput: Sendable, Hashable {
    /// `flagsChanged` with the side-specific modifier state after the change (keyCode identifies the key).
    case flagsChanged(keyCode: KeyCode, modifiers: ModifierKeys, at: MonotonicInstant)
    case keyDown(keyCode: KeyCode, modifiers: ModifierKeys, autorepeat: Bool, at: MonotonicInstant)
    case keyUp(keyCode: KeyCode, at: MonotonicInstant)
    case pointerDown(at: MonotonicInstant)
    case scroll(at: MonotonicInstant)
}

public enum HotkeyResult: Sendable, Hashable {
    case none
    /// Modifier-only tap completed: fire on release of the last modifier (PRD-R14). Modifier events are never
    /// swallowed.
    case toggleTap
    /// Key combo matched on keyDown: the pipeline consumes this keyDown and its keyUp.
    case toggleCombo
    /// The restore binding matched on keyDown: the pipeline feeds `.restoreToggle` to the engine and consumes
    /// the key only if the engine returns an edit (PLT-R353, ENG-R701-R703).
    case restoreCandidate
}

/// Toggle tap: cancels on any other key, mouse button or scroll during the hold, on holds longer than 500 ms,
/// and ignores autorepeat (PRD-R14).
///
/// Auto-repeat events never fire a hotkey and never cancel a tap: they belong to a key pressed before the chord
/// started. A restore binding is recognised only as a key or key combo (it must be a key the pipeline can
/// consume, PRD-R18, PLT-R353); a modifier-only restore binding is ignored. Logic: `HotkeyRecognition.swift`.
public struct HotkeyRecognizer: Sendable {
    public static let maximumTapDuration: TimeSpan = .milliseconds(500)
    let toggle: HotkeyBinding
    let restore: HotkeyBinding?
    var toggleTap: HotkeyChordTracker?

    public init(toggle: HotkeyBinding, restore: HotkeyBinding?) {
        self.toggle = toggle
        self.restore = restore
        toggleTap = HotkeyChordTracker(binding: toggle)
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult { recognize(input) }
}

public enum RecorderState: Sendable, Hashable {
    case idle
    case recording(held: ModifierKeys, key: KeyCode?)
    case finished(HotkeyBinding, conflict: SystemShortcutConflict?)
    case rejected(RecorderRejection)
}

public enum RecorderRejection: String, Sendable, Hashable {
    /// Modifier-only chord outside the PRD-R15 list; for the restore role every modifier-only chord (PRD-R18).
    case unsupportedModifierTap
    case keyWithoutModifierForToggle
}

/// macOS shortcuts the recorder warns about but accepts (PRD-R16).
public enum SystemShortcutConflict: String, Sendable, Hashable, CaseIterable {
    case spotlight  // Command+Space
    case selectPreviousInputSource  // Control+Space
    case selectNextInputSource  // Control+Option+Space
    case characterViewer  // Control+Command+Space
    case appSwitcher  // Command+Tab
    case quitApp  // Command+Q
    case closeWindow  // Command+W
}

/// Captures a binding in any press order and finishes when every key is released (PRD-R15). Logic:
/// `HotkeyRecording.swift`.
public struct HotkeyRecorder: Sendable {
    let role: HotkeyRole
    let layout: LayoutTable?
    var session = HotkeyRecordingSession()
    var state = RecorderState.idle

    public init(role: HotkeyRole) { self.init(role: role, layout: nil) }

    /// `layout` names the conflicts that depend on the typed character (Command+Q, Command+W) on non-US layouts
    /// such as AZERTY or Dvorak; without it the ABC key positions are used.
    public init(role: HotkeyRole, layout: LayoutTable?) {
        self.role = role
        self.layout = layout
    }

    public mutating func handle(_ input: HotkeyInput) -> RecorderState { record(input) }

    public static func conflict(for binding: HotkeyBinding) -> SystemShortcutConflict? {
        conflict(for: binding, layout: nil)
    }

    /// PRD-R16 conflict, resolving letter keys through `layout` when given.
    public static func conflict(for binding: HotkeyBinding, layout: LayoutTable?) -> SystemShortcutConflict? {
        SystemShortcutCatalog.conflict(for: binding, layout: layout)
    }
}
