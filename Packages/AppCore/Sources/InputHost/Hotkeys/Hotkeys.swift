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
public struct HotkeyRecognizer: Sendable {
    public static let maximumTapDuration: Duration = .milliseconds(500)
    public init(toggle: HotkeyBinding, restore: HotkeyBinding?) { unimplemented() }
    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult { unimplemented() }
}

public enum RecorderState: Sendable, Hashable {
    case idle
    case recording(held: ModifierKeys, key: KeyCode?)
    case finished(HotkeyBinding, conflict: SystemShortcutConflict?)
    case rejected(RecorderRejection)
}

public enum RecorderRejection: String, Sendable, Hashable {
    case unsupportedModifierTap  // modifier-only chord outside the PRD-R15 list
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

/// Captures a binding in any press order and finishes when every key is released (PRD-R15).
public struct HotkeyRecorder: Sendable {
    public init(role: HotkeyRole) { unimplemented() }
    public mutating func handle(_ input: HotkeyInput) -> RecorderState { unimplemented() }
    public static func conflict(for binding: HotkeyBinding) -> SystemShortcutConflict? { unimplemented() }
}
