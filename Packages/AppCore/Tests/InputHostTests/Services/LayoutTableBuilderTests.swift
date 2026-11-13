// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R360, PLT-R361, PLT-R354: tables built with UCKeyTranslate from installed system layouts, read by ID.
// Read-only: no input source is selected or enabled.

import AppModel
import Foundation
import Testing

@testable import InputHost

@MainActor
private func systemTable(_ id: String) throws -> LayoutTable {
    let provider = TISInputSourceProvider()
    let data = try #require(provider.layoutData(for: sourceID(id)), "layout \(id) not installed")
    return try UCKeyTranslateLayoutBuilder().build(from: data, keyboardType: provider.currentKeyboardType())
}

private func key(_ raw: UInt16) -> KeyCode { KeyCode(rawValue: raw) }

@Suite("UCKeyTranslate layout tables (PLT-R360, PLT-R361)")
@MainActor
struct LayoutTableBuilderTests {
    @Test func abcLettersCaseAndControlKeys() throws {
        let table = try systemTable("com.apple.keylayout.ABC")
        #expect(table.source == sourceID("com.apple.keylayout.ABC"))
        #expect(table.entry(for: key(0x00), state: .none) == .character("a"))
        #expect(table.entry(for: key(0x00), state: .shift) == .character("A"))
        #expect(table.entry(for: key(0x00), state: .capsLock) == .character("A"))
        #expect(table.entry(for: key(0x10), state: .none) == .character("y"))
        #expect(table.entry(for: key(0x06), state: .none) == .character("z"))
        #expect(table.entry(for: .space, state: .none) == .character(" "))
        for control in [KeyCode.returnKey, .tab, .escape, .delete, .leftArrow, .upArrow] {
            #expect(table.entry(for: control, state: .none) == LayoutEntry.none, "\(control)")
        }
        #expect(table.keyCode(producing: "s") == key(0x01))
    }

    @Test func qwertzSwapsYAndZ() throws {
        let table = try systemTable("com.apple.keylayout.German")
        #expect(table.entry(for: key(0x10), state: .none) == .character("z"))
        #expect(table.entry(for: key(0x06), state: .none) == .character("y"))
        #expect(table.keyCode(producing: "y") == key(0x06))
        #expect(table.keyCode(producing: "z") == key(0x10))
    }

    @Test func azertyLettersAndShiftedDigits() throws {
        let table = try systemTable("com.apple.keylayout.French")
        #expect(table.entry(for: key(0x00), state: .none) == .character("q"))
        #expect(table.entry(for: key(0x0C), state: .none) == .character("a"))
        #expect(table.entry(for: key(0x0D), state: .none) == .character("z"))
        #expect(table.entry(for: key(0x06), state: .none) == .character("w"))
        // VNI digits need Shift on AZERTY (PLT-R361).
        let digitKeys: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (digit, code) in zip("1234567890", digitKeys) {
            #expect(table.entry(for: key(code), state: .shift) == .character(digit), "\(digit)")
        }
        #expect(table.entry(for: key(0x12), state: .none) == .character("&"))
        #expect(table.keyCode(producing: "6") == key(0x16))
    }

    @Test func dvorakPositions() throws {
        let table = try systemTable("com.apple.keylayout.Dvorak")
        #expect(table.entry(for: key(0x01), state: .none) == .character("o"))
        #expect(table.entry(for: key(0x02), state: .none) == .character("e"))
        #expect(table.entry(for: key(0x10), state: .none) == .character("f"))
        #expect(table.keyCode(producing: "s") == key(0x29))
        #expect(table.keyCode(producing: "j") == key(0x08))
    }

    @Test func deadKeysAreFlagged() throws {
        let french = try systemTable("com.apple.keylayout.French")
        #expect(french.entry(for: key(0x21), state: .none) == .deadKey)  // circumflex
        let german = try systemTable("com.apple.keylayout.German")
        #expect(german.entry(for: key(0x18), state: .none) == .deadKey)  // acute
        let abc = try systemTable("com.apple.keylayout.ABC")
        #expect(abc.entry(for: key(0x21), state: .none) == .character("["))
    }

    @Test func keyboardTypeIsRecorded() throws {
        let provider = TISInputSourceProvider()
        let data = try #require(provider.layoutData(for: sourceID("com.apple.keylayout.ABC")))
        let table = try UCKeyTranslateLayoutBuilder().build(from: data, keyboardType: 41)
        #expect(table.keyboardType == 41)
    }

    @Test(arguments: [Data(), Data(repeating: 0xAB, count: 200)])
    func invalidLayoutDataThrows(bytes: Data) {
        let data = KeyboardLayoutData(source: sourceID("test.invalid"), uchr: bytes)
        #expect(throws: LayoutTableError.invalidLayoutData) {
            try UCKeyTranslateLayoutBuilder().build(from: data, keyboardType: 40)
        }
    }

    @Test func modifierKeyStatesMatchCarbonBits() {
        #expect(UCKeyTranslateTable.modifierKeyState(.none) == 0)
        #expect(UCKeyTranslateTable.modifierKeyState(.shift) == 0x02)
        #expect(UCKeyTranslateTable.modifierKeyState(.capsLock) == 0x04)
        #expect(UCKeyTranslateTable.modifierKeyState(.shiftCapsLock) == 0x06)
    }

    @Test func outputClassification() {
        #expect(UCKeyTranslateTable.classify("ơ") == .character("ơ"))
        #expect(UCKeyTranslateTable.classify("\r") == LayoutEntry.none)
        #expect(UCKeyTranslateTable.classify("\u{7F}") == LayoutEntry.none)
        #expect(UCKeyTranslateTable.classify("\u{10}") == LayoutEntry.none)
        #expect(UCKeyTranslateTable.classify("ab") == LayoutEntry.none)
        #expect(UCKeyTranslateTable.classify("") == LayoutEntry.none)
    }
}
