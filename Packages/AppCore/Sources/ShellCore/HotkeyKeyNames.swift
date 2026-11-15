// SPDX-License-Identifier: GPL-3.0-or-later
//
// Display names of key codes for `HotkeyDisplay`. Key codes are physical positions (Carbon `kVK_*` values from
// Apple's HIToolbox Events.h); printable keys are labelled with their ANSI (U.S.) legend. VERIFY with Pa whether
// the recorder should show the active layout's legend instead (it would need UCKeyTranslate, InputHost).

internal import AppModel

enum HotkeyKeyNames {
    static func name(for keyCode: KeyCode, localizer: Localizer) -> String {
        if keyCode == .space { return localizer.string(MenuText.hotkeySpace) }
        if let symbol = symbols[keyCode.rawValue] { return symbol }
        if let legend = ansiLegends[keyCode.rawValue] { return legend }
        if let function = functionKeys[keyCode.rawValue] { return "F\(function)" }
        return localizer.format(MenuText.hotkeyUnknownKey, Int(keyCode.rawValue))
    }

    /// A key in words, as printed on it, for copy that tells the user what to press (`ShortcutWords`, PRD-R78):
    /// non-printing keys by their legend, which reads the same in every interface language like the modifiers, and
    /// the arrow keys by name in the interface language; any other key as `name(for:localizer:)` gives it.
    static func word(for keyCode: KeyCode, localizer: Localizer) -> String {
        if let legend = legends[keyCode.rawValue] { return legend }
        if let arrow = arrows[keyCode.rawValue] { return localizer.string(arrow) }
        return name(for: keyCode, localizer: localizer)
    }

    /// Legends of the non-printing keys other than the arrows.
    private static let legends: [UInt16: String] = [
        KeyCode.returnKey.rawValue: "Return", KeyCode.tab.rawValue: "Tab", KeyCode.delete.rawValue: "Delete",
        KeyCode.escape.rawValue: "Escape", KeyCode.forwardDelete.rawValue: "Forward Delete",
        KeyCode.home.rawValue: "Home", KeyCode.end.rawValue: "End", KeyCode.pageUp.rawValue: "Page Up",
        KeyCode.pageDown.rawValue: "Page Down", KeyCode.keypadEnter.rawValue: "Enter",
    ]

    private static let arrows: [UInt16: MenuText] = [
        KeyCode.leftArrow.rawValue: .hotkeyLeftArrow, KeyCode.rightArrow.rawValue: .hotkeyRightArrow,
        KeyCode.upArrow.rawValue: .hotkeyUpArrow, KeyCode.downArrow.rawValue: .hotkeyDownArrow,
    ]

    /// Apple's symbols for non-printing keys.
    private static let symbols: [UInt16: String] = [
        KeyCode.returnKey.rawValue: "↩", KeyCode.tab.rawValue: "⇥", KeyCode.delete.rawValue: "⌫",
        KeyCode.escape.rawValue: "⎋", KeyCode.forwardDelete.rawValue: "⌦", KeyCode.home.rawValue: "↖",
        KeyCode.end.rawValue: "↘", KeyCode.pageUp.rawValue: "⇞", KeyCode.pageDown.rawValue: "⇟",
        KeyCode.leftArrow.rawValue: "←", KeyCode.rightArrow.rawValue: "→", KeyCode.downArrow.rawValue: "↓",
        KeyCode.upArrow.rawValue: "↑", KeyCode.keypadEnter.rawValue: "⌤",
    ]

    /// ANSI legends by position (kVK_ANSI_*).
    private static let ansiLegends: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C",
        0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-",
        0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x32: "`",
    ]

    /// kVK_F1...kVK_F20.
    private static let functionKeys: [UInt16: Int] = [
        0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4, 0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8, 0x65: 9, 0x6D: 10, 0x67: 11,
        0x6F: 12, 0x69: 13, 0x6B: 14, 0x71: 15, 0x6A: 16, 0x40: 17, 0x4F: 18, 0x50: 19, 0x5A: 20,
    ]
}
