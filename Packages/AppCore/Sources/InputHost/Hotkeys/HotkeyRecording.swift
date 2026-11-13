// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Hotkey recorder logic (PRD-R15, PRD-R16, PRD-R18) and the catalogue of macOS shortcuts it warns about.

import AppModel

/// What has been pressed since the recording started. The binding is the union of every modifier held during
/// the recording plus the last non-modifier key, so the press order does not matter (PRD-R15: "must press
/// Space before Control" is fixed by construction).
struct HotkeyRecordingSession: Sendable, Hashable {
    var active = false
    var held: ModifierKeys = []
    var maxHeld: ModifierKeys = []
    var key: KeyCode?
    var keysDown: Set<KeyCode> = []
}

extension HotkeyRecorder {
    mutating func record(_ input: HotkeyInput) -> RecorderState {
        switch input {
        case .flagsChanged(let keyCode, let modifiers, _):
            let held = HotkeyKeys.normalized(modifiers, keyCode: keyCode)
            if !session.active {
                guard !held.isEmpty else { return state }
                session = HotkeyRecordingSession(active: true)
            }
            session.held = held
            session.maxHeld.formUnion(held)
            return finishIfReleased()
        case .keyDown(let keyCode, let modifiers, let autorepeat, _):
            guard !autorepeat else { return state }
            if !session.active { session = HotkeyRecordingSession(active: true) }
            session.keysDown.insert(keyCode)
            session.key = keyCode
            session.maxHeld.formUnion(HotkeyKeys.normalized(modifiers, keyCode: keyCode))
            state = .recording(held: session.maxHeld, key: keyCode)
            return state
        case .keyUp(let keyCode, _):
            guard session.active else { return state }
            session.keysDown.remove(keyCode)
            return finishIfReleased()
        case .pointerDown, .scroll:
            return state
        }
    }

    private mutating func finishIfReleased() -> RecorderState {
        guard session.held.isEmpty, session.keysDown.isEmpty else {
            state = .recording(held: session.maxHeld, key: session.key)
            return state
        }
        state = finish()
        session = HotkeyRecordingSession()
        return state
    }

    private func finish() -> RecorderState {
        if let key = session.key {
            let modifiers = session.maxHeld.intersection(HotkeyKeys.genericModifiers)
            guard !modifiers.isEmpty else {
                // A single key is allowed only for "Restore last word" (Escape is the suggestion, D8).
                return role == .toggleMode
                    ? .rejected(.keyWithoutModifierForToggle) : .finished(.key(key), conflict: nil)
            }
            let binding = HotkeyBinding.keyCombo(modifiers: modifiers, keyCode: key)
            return .finished(binding, conflict: SystemShortcutCatalog.conflict(for: binding, layout: layout))
        }
        // PRD-R18: the restore binding must be a key the pipeline can consume, so modifier-only taps are refused.
        guard role == .toggleMode, let chord = Self.chord(matching: session.maxHeld) else {
            return .rejected(.unsupportedModifierTap)
        }
        return .finished(.modifierTap(chord), conflict: nil)
    }

    /// Exact match first (right Command alone), then the same set without side bits (right Command + Shift is
    /// Command+Shift).
    static func chord(matching held: ModifierKeys) -> ModifierTapChord? {
        if let exact = ModifierTapChord.allCases.first(where: { $0.modifiers == held }) { return exact }
        let generic = held.subtracting(HotkeyKeys.sideModifiers)
        return ModifierTapChord.allCases.first { chord in
            chord.modifiers.intersection(HotkeyKeys.sideModifiers).isEmpty && chord.modifiers == generic
        }
    }
}

/// PRD-R16: the seven macOS shortcuts the recorder accepts with a warning.
enum SystemShortcutCatalog {
    /// ABC key positions of Q and W, used when no layout table is given.
    static let ansiQ = KeyCode(rawValue: 0x0C)
    static let ansiW = KeyCode(rawValue: 0x0D)

    static func conflict(for binding: HotkeyBinding, layout: LayoutTable?) -> SystemShortcutConflict? {
        guard case .keyCombo(let bound, let keyCode) = binding else { return nil }
        let modifiers = bound.intersection(HotkeyKeys.genericModifiers)
        switch keyCode {
        case .space:
            switch modifiers {
            case [.command]: return .spotlight
            case [.control]: return .selectPreviousInputSource
            case [.control, .option]: return .selectNextInputSource
            case [.control, .command]: return .characterViewer
            default: return nil
            }
        case .tab:
            return modifiers == [.command] ? .appSwitcher : nil
        default:
            guard modifiers == [.command] else { return nil }
            switch letter(for: keyCode, layout: layout) {
            case "q": return .quitApp
            case "w": return .closeWindow
            default: return nil
            }
        }
    }

    /// Command shortcuts follow the character the key types, so AZERTY's Q (ABC position A) is Command+Q.
    private static func letter(for keyCode: KeyCode, layout: LayoutTable?) -> Character? {
        guard let layout else {
            switch keyCode {
            case ansiQ: return "q"
            case ansiW: return "w"
            default: return nil
            }
        }
        guard case .character(let character) = layout.entry(for: keyCode, state: .none) else { return nil }
        return character.lowercased().first
    }
}
