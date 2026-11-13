// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Layout table construction with `UCKeyTranslate` (PLT-R360, PLT-R361, PLT-R354). Runs off the tap thread on
// the layout's `uchr` bytes; the result is a fixed 128 x 4 array the tap indexes without allocating.

import AppModel
import Carbon
import Foundation

enum UCKeyTranslateTable {
    /// `modifierKeyState` argument for each table state: Carbon modifier bits shifted right by 8 (`shiftKey` is
    /// bit 9, `alphaLock` bit 10).
    static func modifierKeyState(_ state: LayoutModifierState) -> UInt32 {
        let shift = UInt32(shiftKey >> 8) & 0xFF
        let capsLock = UInt32(alphaLock >> 8) & 0xFF
        switch state {
        case .none: return 0
        case .shift: return shift
        case .capsLock: return capsLock
        case .shiftCapsLock: return shift | capsLock
        }
    }

    static func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws(LayoutTableError) -> LayoutTable {
        let count = data.uchr.count
        guard count >= MemoryLayout<UCKeyboardLayout>.size else { throw .invalidLayoutData }
        // Copy into an aligned buffer: `Data` storage carries no alignment guarantee for the header fields.
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: count, alignment: MemoryLayout<UCKeyboardLayout>.alignment)
        defer { buffer.deallocate() }
        data.uchr.copyBytes(to: buffer)
        let layout = buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        guard layout.pointee.keyLayoutHeaderFormat == UInt16(kUCKeyLayoutHeaderFormat),
            layout.pointee.keyboardTypeCount > 0
        else { throw .invalidLayoutData }

        var entries = [LayoutEntry](
            repeating: .none, count: LayoutTable.keyCodeCount * LayoutModifierState.allCases.count)
        for code in 0..<LayoutTable.keyCodeCount {
            for state in LayoutModifierState.allCases {
                entries[code * 4 + state.rawValue] = try entry(
                    layout: layout, keyCode: UInt16(code), state: state, keyboardType: keyboardType)
            }
        }
        return LayoutTable(source: data.source, keyboardType: keyboardType, entries: entries)
    }

    private static func entry(
        layout: UnsafePointer<UCKeyboardLayout>, keyCode: UInt16, state: LayoutModifierState, keyboardType: UInt32
    ) throws(LayoutTableError) -> LayoutEntry {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters: [UniChar] = [0, 0, 0, 0]
        // Options 0: dead-key processing on, so a dead key reports no output and a non-zero state (PLT-R354).
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), modifierKeyState(state), keyboardType, 0, &deadKeyState,
            characters.count, &length, &characters)
        guard status == noErr else { throw .translationFailed(status: status) }
        guard length > 0 else { return deadKeyState != 0 ? .deadKey : .none }
        return classify(String(utf16CodeUnits: characters, count: length))
    }

    /// One printable character, or `.none` for control output (Return, Tab, Escape, arrows, function keys use
    /// characters below U+0020 or U+007F) and for multi-character output.
    static func classify(_ output: String) -> LayoutEntry {
        guard output.count == 1, let character = output.first else { return .none }
        let isControl = character.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7F }
        return isControl ? .none : .character(character)
    }
}
