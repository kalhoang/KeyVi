// SPDX-License-Identifier: GPL-3.0-or-later
//
// A small reference implementation of the recogniser contract (contracts.md 10.2, PRD-R14, PRD-R15, PRD-R18)
// so the pipeline's suites run independently of W1-E's `HotkeyRecognizer`. Test support only; the production
// recogniser is W1-E's and the property suite can switch to it with `ScriptedEngineFactory.Hotkeys`.

public import AppModel
public import InputHost
internal import RealtimeSupport

public struct ReferenceHotkeyRecognizer: HotkeyRecognizing {
    private let toggle: HotkeyBinding
    private let restore: HotkeyBinding?
    /// `ModifierTapChord.modifiers` builds its set from an array literal, which allocates in unoptimised
    /// builds, so the chord is resolved once here and never on the tap path (PLT-R305).
    private let tapModifiers: ModifierKeys?
    private var held: ModifierKeys = []
    private var maximumHeld: ModifierKeys = []
    private var pressedAt: MonotonicInstant?
    private var cancelled = false

    public init(toggle: HotkeyBinding, restore: HotkeyBinding?) {
        self.toggle = toggle
        self.restore = restore
        if case .modifierTap(let chord) = toggle { tapModifiers = chord.modifiers } else { tapModifiers = nil }
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult {
        switch input {
        case .flagsChanged(_, let modifiers, let at):
            return modifiersChanged(to: modifiers, at: at)
        case .keyDown(let keyCode, let modifiers, let autorepeat, _):
            if pressedAt != nil { cancelled = true }  // used with another key: never a tap
            guard !autorepeat else { return .none }
            if case .keyCombo(let bound, let code) = toggle, code == keyCode, Self.matches(modifiers, bound) {
                return .toggleCombo
            }
            switch restore {
            case .key(let code)? where code == keyCode && modifiers.isEmpty: return .restoreCandidate
            case .keyCombo(let bound, let code)? where code == keyCode && Self.matches(modifiers, bound):
                return .restoreCandidate
            default: return .none
            }
        case .keyUp:
            return .none
        case .pointerDown, .scroll:
            if pressedAt != nil { cancelled = true }
            return .none
        }
    }

    private mutating func modifiersChanged(to modifiers: ModifierKeys, at: MonotonicInstant) -> HotkeyResult {
        guard let chord = tapModifiers else {
            held = modifiers
            return .none
        }
        if held.isEmpty && !modifiers.isEmpty {
            pressedAt = at
            maximumHeld = []
            cancelled = false
        }
        maximumHeld.formUnion(modifiers)
        if !chord.isSuperset(of: maximumHeld) { cancelled = true }
        held = modifiers
        guard modifiers.isEmpty, let start = pressedAt else { return .none }
        pressedAt = nil
        let quick = at.nanoseconds(since: start) <= 500_000_000  // PRD-R14: 500 ms
        return !cancelled && quick && maximumHeld == chord ? .toggleTap : .none
    }

    /// Exact modifier match; side bits count only when the binding names a side.
    private static func matches(_ modifiers: ModifierKeys, _ bound: ModifierKeys) -> Bool {
        var actual = modifiers
        if !bound.contains(.rightCommand) { actual.remove(.rightCommand) }
        if !bound.contains(.rightOption) { actual.remove(.rightOption) }
        return actual == bound
    }
}
