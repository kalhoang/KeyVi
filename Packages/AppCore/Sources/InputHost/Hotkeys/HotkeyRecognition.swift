// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Toggle recogniser logic (PRD-R14, PRD-R18, contracts.md 10.2). Pure value code: runs on the tap thread inside
// the pipeline, so it never allocates in steady state (fixed-size state, no collections).

import AppModel
import RealtimeSupport

/// Key and modifier helpers shared by the recogniser and the recorder. Namespaced instead of extending the shared
/// AppModel types, so other workstreams' extensions cannot collide with these names.
enum HotkeyKeys {
    /// Modifiers compared for combos and for chords that are not side-specific.
    static let genericModifiers: ModifierKeys = [.control, .option, .shift, .command]
    static let sideModifiers: ModifierKeys = [.rightCommand, .rightOption]

    /// Physical modifier keys whose `flagsChanged` events build a chord. Caps Lock is not one of them: pressing it
    /// during a tap counts as another key (PRD-R14).
    static func isModifierKey(_ keyCode: KeyCode) -> Bool {
        switch keyCode {
        case .command, .rightCommand, .shift, .rightShift, .option, .rightOption, .control, .rightControl,
            .function:
            true
        default: false
        }
    }

    /// Adds the side-specific bit from the event's keycode (`kVK_RightCommand`, `kVK_RightOption`) when the
    /// pipeline reported only the generic modifier (contracts.md 10.2).
    static func normalized(_ modifiers: ModifierKeys, keyCode: KeyCode) -> ModifierKeys {
        var result = modifiers
        if keyCode == .rightCommand, modifiers.contains(.command) { result.insert(.rightCommand) }
        if keyCode == .rightOption, modifiers.contains(.option) { result.insert(.rightOption) }
        return result
    }

    /// True when `binding` is a key or key combo matching this keyDown. Only the four generic modifiers count:
    /// macOS sets the function flag on arrow and F-keys by itself, and combos do not care which side was used.
    static func matches(_ binding: HotkeyBinding, keyCode: KeyCode, modifiers: ModifierKeys) -> Bool {
        let held = modifiers.intersection(genericModifiers)
        switch binding {
        case .keyCombo(let bound, let boundKey):
            let required = bound.intersection(genericModifiers)
            return boundKey == keyCode && !required.isEmpty && required == held
        case .key(let boundKey):
            return boundKey == keyCode && held.isEmpty
        case .modifierTap:
            return false
        }
    }
}

/// State machine of one modifier-only tap (PRD-R14): idle -> arming while the held set grows towards the chord
/// in any press order -> fires when the last modifier is released, the maximum held set equals the chord and no
/// more than 500 ms passed since the first press. Any other key, pointer down, scroll, extra modifier or a hold
/// over 500 ms cancels until every modifier is released.
struct HotkeyChordTracker: Sendable {
    enum Phase: Sendable, Hashable {
        case idle
        case arming(start: MonotonicInstant, maxHeld: ModifierKeys)
        case cancelled
    }

    let chord: ModifierKeys
    /// Right Command or right Option alone: side bits are compared; otherwise they are ignored, so Command+Shift
    /// works with either Command key.
    let sideSpecific: Bool
    private(set) var phase = Phase.idle

    init?(binding: HotkeyBinding) {
        guard case .modifierTap(let chord) = binding else { return nil }
        self.chord = chord.modifiers
        sideSpecific = !chord.modifiers.intersection(HotkeyKeys.sideModifiers).isEmpty
    }

    /// Returns true when the tap completed with this release.
    mutating func flagsChanged(keyCode: KeyCode, modifiers: ModifierKeys, at instant: MonotonicInstant) -> Bool {
        let normalized = HotkeyKeys.normalized(modifiers, keyCode: keyCode)
        let held = sideSpecific ? normalized : normalized.subtracting(HotkeyKeys.sideModifiers)
        guard HotkeyKeys.isModifierKey(keyCode) else {
            phase = held.isEmpty ? .idle : .cancelled
            return false
        }
        switch phase {
        case .idle:
            if !held.isEmpty { phase = held.isSubset(of: chord) ? .arming(start: instant, maxHeld: held) : .cancelled }
            return false
        case .arming(let start, let maxHeld):
            let withinLimit = instant.nanoseconds(since: start) <= Self.maximumTapNanoseconds
            if held.isEmpty {
                phase = .idle
                return withinLimit && maxHeld == chord
            }
            let growing = withinLimit && held.isSubset(of: chord)
            phase = growing ? .arming(start: start, maxHeld: maxHeld.union(held)) : .cancelled
            return false
        case .cancelled:
            if held.isEmpty { phase = .idle }
            return false
        }
    }

    /// A key, pointer down or scroll happened (PRD-R14).
    mutating func interrupt() {
        if case .arming = phase { phase = .cancelled }
    }

    static let maximumTapNanoseconds: UInt64 = HotkeyRecognizer.maximumTapDuration.unsignedNanoseconds
}

extension HotkeyRecognizer {
    mutating func recognize(_ input: HotkeyInput) -> HotkeyResult {
        switch input {
        case .flagsChanged(let keyCode, let modifiers, let instant):
            let fired = toggleTap?.flagsChanged(keyCode: keyCode, modifiers: modifiers, at: instant) ?? false
            return fired ? .toggleTap : .none
        case .keyDown(let keyCode, let modifiers, let autorepeat, _):
            // PRD-R14: auto-repeat is ignored; a repeated combo key never toggles twice.
            guard !autorepeat else { return .none }
            toggleTap?.interrupt()
            if HotkeyKeys.matches(toggle, keyCode: keyCode, modifiers: modifiers) { return .toggleCombo }
            if let restore, HotkeyKeys.matches(restore, keyCode: keyCode, modifiers: modifiers) {
                return .restoreCandidate
            }
            return .none
        case .keyUp:
            // A keyDown during the hold already cancelled; a keyUp can only end a key pressed before the chord.
            return .none
        case .pointerDown, .scroll:
            toggleTap?.interrupt()
            return .none
        }
    }
}
