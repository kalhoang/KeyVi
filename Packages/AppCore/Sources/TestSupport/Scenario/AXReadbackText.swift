// SPDX-License-Identifier: GPL-3.0-or-later
//
// The text of the `ax` readback (QA-R21, PLT-R530). A field that completes inline (Spotlight with history shows
// "text" as "TextEdit" with "Edit" selected, `launcher.spotlight`) holds the selected completion in its value. The
// typed text is the part before a selection that runs to the end of the value, the same assumption the
// `axSelection` strategy makes (PLT-R353). A collapsed selection, or one that ends before the end of the value, is
// not a completion and keeps the whole value.

/// What the `ax` readback reads of a field: its whole `kAXValueAttribute` and its `kAXSelectedTextRangeAttribute`
/// (nil when the field has none). The reader strips nothing; `ReadbackRouter` decides what is compared.
public struct AXFieldState: Sendable, Hashable {
    public var value: String
    public var selection: AXReadbackText.Selection?

    public init(value: String, selection: AXReadbackText.Selection? = nil) {
        self.value = value
        self.selection = selection
    }
}

public enum AXReadbackText {
    /// `kAXSelectedTextRangeAttribute` in UTF-16 units.
    public struct Selection: Sendable, Hashable {
        public var location: Int
        public var length: Int
        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public static func typed(value: String, selection: Selection?) -> String {
        let units = value.utf16
        guard let selection, selection.length > 0, selection.location >= 0,
            selection.location + selection.length == units.count,
            let end = units.index(units.startIndex, offsetBy: selection.location, limitedBy: units.endIndex),
            let prefix = String(units[units.startIndex..<end])
        else { return value }
        return prefix
    }
}
