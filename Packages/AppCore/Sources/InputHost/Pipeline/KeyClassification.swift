// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R310 step 7: keycode plus modifier state -> key class, through the precomputed layout table (PLT-R360).
// Pure and tap-safe: integer tests, one array read, no allocation.

internal import AppModel

enum KeyClassification {
    @inline(__always)
    static func classify(_ event: RawKeyEvent, table: LayoutTable?) -> KeyClass {
        switch event.kind {
        case .flagsChanged: return .modifierOnly
        case .keyDown, .keyUp: break
        default: return .unmapped
        }
        let flags = event.flags
        // PLT-R350: any key with Command or Control is a chord (a hard boundary), whatever it produces.
        if flags & (EventFlags.command | EventFlags.control) != 0 { return .commandOrControlChord }
        switch VirtualKeyGroup.of(event.keyCode) {
        // Option+Delete deletes a word in Cocoa: the caret moves over committed text like navigation.
        case .backspace: return flags & EventFlags.option != 0 ? .navigation : .backspace
        case .forwardDelete: return .forwardDelete
        case .escape: return .escape
        case .returnKey: return .returnKey
        case .tab: return .tab
        case .navigation: return .navigation
        case .function: return .functionKey
        case .other: break
        }
        // PLT-R350: Option states are classified, not translated.
        if flags & EventFlags.option != 0 { return .optionChord }
        guard let table else { return .unmapped }
        switch table.entry(for: event.keyCode, state: EventFlags.layoutState(flags)) {
        case .character(let character):
            return .character(character, fromKeypad: VirtualKeyGroup.isKeypadCharacter(event.keyCode))
        case .deadKey: return .deadKey  // PLT-R354
        case .none: return .unmapped
        }
    }

    /// PLT-R363 (debug builds): does the table agree with the Unicode string of a physical event? An empty
    /// string (some sources leave it unset, VERIFY) is not a mismatch.
    static func layoutAgrees(with event: RawKeyEvent, character: Character) -> Bool {
        guard event.unicode.count > 0 else { return true }
        return event.unicode.withUnits { units in character.utf16.elementsEqual(units) }
    }
}
