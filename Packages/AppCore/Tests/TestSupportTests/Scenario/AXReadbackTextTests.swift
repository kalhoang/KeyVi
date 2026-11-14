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

    /// The range is in UTF-16 units (kAXSelectedTextRangeAttribute); out-of-range values are ignored.
    @Test func utf16RangesAndOutOfRangeSelections() {
        #expect(typed("😀ab", 2, 2) == "😀")
        #expect(typed("ab", 1, 5) == "ab")
        #expect(typed("ab", -1, 3) == "ab")
    }
}
