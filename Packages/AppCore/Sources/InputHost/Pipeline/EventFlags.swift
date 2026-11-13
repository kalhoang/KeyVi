// SPDX-License-Identifier: GPL-3.0-or-later
//
// Event flag bits and virtual key codes the pipeline reads. Literal constants (tap-safe, no lazy globals);
// `PipelineConstantsTests` checks them against CoreGraphics. Key codes are the public macOS virtual key codes
// (Carbon `Events.h`, `kVK_*`); device-dependent modifier bits are the public `NX_DEVICE*KEYMASK` values of
// IOKit's `IOLLEvent.h`.

internal import AppModel

enum EventFlags {
    static let capsLock: UInt64 = 0x0001_0000  // CGEventFlags.maskAlphaShift
    static let shift: UInt64 = 0x0002_0000  // .maskShift
    static let control: UInt64 = 0x0004_0000  // .maskControl
    static let option: UInt64 = 0x0008_0000  // .maskAlternate
    static let command: UInt64 = 0x0010_0000  // .maskCommand
    static let numericPad: UInt64 = 0x0020_0000  // .maskNumericPad
    static let leftCommandDevice: UInt64 = 0x0000_0008  // NX_DEVICELCMDKEYMASK
    static let rightCommandDevice: UInt64 = 0x0000_0010  // NX_DEVICERCMDKEYMASK
    static let leftOptionDevice: UInt64 = 0x0000_0020  // NX_DEVICELALTKEYMASK
    static let rightOptionDevice: UInt64 = 0x0000_0040  // NX_DEVICERALTKEYMASK

    /// The side-specific modifier set of contracts.md 10.2. `.rightCommand` / `.rightOption` are set only when
    /// the right key is the one held (PRD-R15 right-side taps). Fn/Globe is not mapped (PRD-R17 VERIFY).
    @inline(__always)
    static func modifierKeys(_ flags: UInt64) -> ModifierKeys {
        var keys: ModifierKeys = []
        if flags & control != 0 { keys.insert(.control) }
        if flags & option != 0 {
            keys.insert(.option)
            if flags & rightOptionDevice != 0 && flags & leftOptionDevice == 0 { keys.insert(.rightOption) }
        }
        if flags & shift != 0 { keys.insert(.shift) }
        if flags & command != 0 {
            keys.insert(.command)
            if flags & rightCommandDevice != 0 && flags & leftCommandDevice == 0 { keys.insert(.rightCommand) }
        }
        return keys
    }

    /// Shift and Caps Lock select the layout-table column (PLT-R350); other modifiers are classified.
    @inline(__always)
    static func layoutState(_ flags: UInt64) -> LayoutModifierState {
        switch (flags & shift != 0, flags & capsLock != 0) {
        case (false, false): .none
        case (true, false): .shift
        case (false, true): .capsLock
        case (true, true): .shiftCapsLock
        }
    }
}

/// Key groups of PLT-R340 and PLT-R350 to PLT-R356 by virtual key code.
enum VirtualKeyGroup {
    case backspace, forwardDelete, escape, returnKey, tab, navigation, function, other

    @inline(__always)
    static func of(_ keyCode: KeyCode) -> VirtualKeyGroup {
        switch keyCode.rawValue {
        case 0x33: .backspace  // kVK_Delete
        case 0x75: .forwardDelete  // kVK_ForwardDelete
        case 0x35: .escape  // kVK_Escape
        case 0x24, 0x4C: .returnKey  // kVK_Return, kVK_ANSI_KeypadEnter
        case 0x30: .tab  // kVK_Tab
        // kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown
        case 0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79: .navigation
        // kVK_F1...kVK_F20, kVK_Help, kVK_VolumeUp, kVK_VolumeDown, kVK_Mute
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40,
            0x4F, 0x50, 0x5A, 0x72, 0x48, 0x49, 0x4A:
            .function
        default: .other
        }
    }

    /// Keypad keys that produce characters (kVK_ANSI_Keypad0...9, Decimal, Multiply, Plus, Clear, Divide,
    /// Minus, Equals). Keypad Enter is a Return key (PLT-R355 flags the rest as `fromKeypad`).
    @inline(__always)
    static func isKeypadCharacter(_ keyCode: KeyCode) -> Bool {
        switch keyCode.rawValue {
        case 0x52...0x59, 0x5B, 0x5C, 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4E, 0x51: true
        default: false
        }
    }
}
