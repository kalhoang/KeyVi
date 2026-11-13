// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The Settings hotkey recorder (PRD-R15, PRD-R16, PRD-R18) over InputHost's `HotkeyRecorder`. The window feeds it
// the raw key code and modifier flags of its own key events while recording; the tap's hotkeys are suspended
// meanwhile (ADR 0305, `InputHostController.setRecorderActive`).

public import AppModel
public import Foundation
public import InputHost
internal import RealtimeSupport

/// One key event of the Settings window, with `NSEvent.modifierFlags.rawValue` (same bit layout as
/// `CGEventFlags`, including the device-dependent side bits).
public enum RecorderKeyEvent: Sendable, Hashable {
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    case keyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
}

public struct HotkeyRecorderSession: Sendable {
    public let role: HotkeyRole
    private var recorder: HotkeyRecorder
    public private(set) var state: RecorderState = .idle

    /// `layout` lets the PRD-R16 check name Command+Q and Command+W on AZERTY or Dvorak.
    public init(role: HotkeyRole, layout: LayoutTable? = nil) {
        self.role = role
        recorder = HotkeyRecorder(role: role, layout: layout)
    }

    /// Feeds one event in any press order (PRD-R15). The recorder never times out: holding keys while deciding
    /// is fine, and only the release finishes a recording.
    @discardableResult
    public mutating func handle(_ event: RecorderKeyEvent) -> RecorderState {
        state = recorder.handle(Self.input(for: event))
        return state
    }

    /// The binding to save, if the recording finished. Conflicts are accepted with a warning (PRD-R16).
    public var finishedBinding: HotkeyBinding? {
        if case .finished(let binding, _) = state { return binding }
        return nil
    }

    static func input(for event: RecorderKeyEvent) -> HotkeyInput {
        switch event {
        case .flagsChanged(let keyCode, let flags):
            .flagsChanged(keyCode: KeyCode(rawValue: keyCode), modifiers: modifierKeys(flags), at: .zero)
        case .keyDown(let keyCode, let flags, let isRepeat):
            .keyDown(
                keyCode: KeyCode(rawValue: keyCode), modifiers: modifierKeys(flags), autorepeat: isRepeat, at: .zero)
        case .keyUp(let keyCode):
            .keyUp(keyCode: KeyCode(rawValue: keyCode), at: .zero)
        }
    }

    /// Side-specific modifier set (contracts.md 10.2): `.rightCommand` / `.rightOption` only when the right key is
    /// the one held. Bits: `NSEvent.ModifierFlags` / `CGEventFlags` and IOKit's `NX_DEVICE*KEYMASK`.
    static func modifierKeys(_ flags: UInt64) -> ModifierKeys {
        var keys: ModifierKeys = []
        if flags & Flags.control != 0 { keys.insert(.control) }
        if flags & Flags.option != 0 {
            keys.insert(.option)
            if flags & Flags.rightOption != 0, flags & Flags.leftOption == 0 { keys.insert(.rightOption) }
        }
        if flags & Flags.shift != 0 { keys.insert(.shift) }
        if flags & Flags.command != 0 {
            keys.insert(.command)
            if flags & Flags.rightCommand != 0, flags & Flags.leftCommand == 0 { keys.insert(.rightCommand) }
        }
        return keys
    }

    enum Flags {
        static let shift: UInt64 = 0x0002_0000
        static let control: UInt64 = 0x0004_0000
        static let option: UInt64 = 0x0008_0000
        static let command: UInt64 = 0x0010_0000
        static let leftCommand: UInt64 = 0x0000_0008
        static let rightCommand: UInt64 = 0x0000_0010
        static let leftOption: UInt64 = 0x0000_0020
        static let rightOption: UInt64 = 0x0000_0040
    }
}

/// Copy of the recorder (Settings table).
public enum HotkeyRecorderText {
    /// The line shown while recording or after it ended.
    public static func status(_ state: RecorderState, role: HotkeyRole, appName: String, localizer: Localizer)
        -> String?
    {
        switch state {
        case .idle: nil
        case .recording(let held, let key):
            live(held: held, key: key, localizer: localizer) ?? localizer.string(SettingsText.hotkeyRecording)
        case .finished(_, let conflict?): conflictMessage(conflict, appName: appName, localizer: localizer)
        case .finished(_, nil): nil
        case .rejected(let rejection): localizer.string(rejectionText(rejection, role: role))
        }
    }

    /// Modifiers and key held so far ("⌃⇧", "⌥⌘K"), or nil before anything is held.
    static func live(held: ModifierKeys, key: KeyCode?, localizer: Localizer) -> String? {
        let symbols = HotkeyDisplay.modifierSymbols(held)
        let name = key.map { HotkeyKeyNames.name(for: $0, localizer: localizer) } ?? ""
        let text = symbols + name
        return text.isEmpty ? nil : text
    }

    public static func rejectionText(_ rejection: RecorderRejection, role: HotkeyRole) -> SettingsText {
        switch rejection {
        case .unsupportedModifierTap:
            role == .restoreLastWord ? .hotkeyRejectedRestoreModifierTap : .hotkeyRejectedModifierTap
        case .keyWithoutModifierForToggle: .hotkeyRejectedKeyWithoutModifier
        }
    }

    /// PRD-R16: names the macOS feature; the binding is still saved.
    public static func conflictMessage(_ conflict: SystemShortcutConflict, appName: String, localizer: Localizer)
        -> String
    {
        localizer.format(SettingsText.hotkeyConflict, localizer.string(feature(conflict)), appName)
    }

    public static func feature(_ conflict: SystemShortcutConflict) -> SettingsText {
        switch conflict {
        case .spotlight: .conflictSpotlight
        case .selectPreviousInputSource: .conflictPreviousSource
        case .selectNextInputSource: .conflictNextSource
        case .characterViewer: .conflictCharacterViewer
        case .appSwitcher: .conflictAppSwitcher
        case .quitApp: .conflictQuitApp
        case .closeWindow: .conflictCloseWindow
        }
    }

    /// PRD-R16 help page on the product site, in the interface language. The host comes from `Brand`.
    public static func helpURL(siteHost: String, localizer: Localizer) -> URL? {
        guard !siteHost.isEmpty else { return nil }
        return URL(string: "https://" + siteHost + localizer.string(SettingsText.hotkeyConflictHelpPath))
    }

    /// Current binding as shown next to the recorder; nil (restore key unset or none) reads "Chưa đặt".
    public static func display(_ binding: HotkeyBinding?, localizer: Localizer) -> String {
        guard let binding else { return localizer.string(SettingsText.hotkeyNotSet) }
        return HotkeyDisplay.string(for: binding, localizer: localizer)
    }
}
