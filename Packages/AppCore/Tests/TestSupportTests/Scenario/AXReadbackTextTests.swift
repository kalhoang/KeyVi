// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `ax` readback of a field that completes inline (QA-R21, PLT-R530): Spotlight with history shows "text" as
// "TextEdit" with "Edit" selected, so the typed text is the part before a selection that runs to the end of the value.

import Testing

@testable import TestSupport

/// The readback of `value` with the UTF-16 selection `location`, `length` (nil: no selection attribute).
private func typed(_ value: String, _ location: Int? = nil, _ length: Int = 0) -> String {
    let selection = location.map { AXReadbackText.Selection(location: $0, length: length) }
    return AXReadbackText.typed(value: value, selection: selection)
}

@Suite struct AXReadbackTextTests {
    @Test func aSelectedCompletionAtTheEndIsNotTypedText() {
        #expect(typed("TextEdit", 4, 4) == "Text")
        #expect(typed("việt nam", 4, 4) == "việt")
    }

    @Test func aCollapsedOrMissingSelectionKeepsTheWholeValue() {
        #expect(typed("text", 4, 0) == "text")
        #expect(typed("text") == "text")
    }

    /// Only a selection that runs to the end is a completion; a selection inside the text is the user's.
    @Test func aSelectionInsideTheValueKeepsTheWholeValue() {
        #expect(typed("hello world", 0, 5) == "hello world")
    }

    /// The failure focus report gives the focused element's selection and character count, numbers only (PLT-R901),
    /// so an evidence file tells a readback that left a completion out ("Đức" with "ức" selected: 1,2 and 3) from a
    /// lost completion (1,0 and 1) without a probe (testhost.sheetCell.columnAutocomplete, run of 19/11/2026).
    @Test func focusReportLinesCarryNumbersOnlyPltR901() {
        #expect(
            AXReadbackText.focusReportLines(selection: .init(location: 1, length: 2), characters: 3) == [
                "focused selection: 1,2", "focused characters: 3",
            ])
        #expect(
            AXReadbackText.focusReportLines(selection: nil, characters: nil) == [
                "focused selection: none", "focused characters: none",
            ])
    }

    /// The range is in UTF-16 units (kAXSelectedTextRangeAttribute); out-of-range values are ignored.
    @Test func utf16RangesAndOutOfRangeSelections() {
        #expect(typed("😀ab", 2, 2) == "😀")
        #expect(typed("ab", 1, 5) == "ab")
        #expect(typed("ab", -1, 3) == "ab")
    }
}
