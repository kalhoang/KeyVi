// SPDX-License-Identifier: MPL-2.0

/// Minimal edits between two displays (6.2, 6.4).
///
/// The engine only produces ASCII and precomposed Vietnamese letters, all single scalars in the Basic
/// Multilingual Plane and none combining (ENG-R102), so for every engine-produced span one character
/// (grapheme cluster) is one Unicode scalar is one UTF-16 code unit (ENG-R631). Displays are compared
/// scalar by scalar; `deleteUTF16Count` is still computed from the scalars so that a test can assert
/// the equality instead of assuming it.
package enum DisplayEdit {
    /// ENG-R611: the longest common prefix of `old` and `new`, by character; delete the rest of `old`
    /// and insert the rest of `new`.
    package static func edit(from old: String, to new: String) -> TextEdit {
        let oldScalars = old.unicodeScalars
        let newScalars = new.unicodeScalars
        var oldIndex = oldScalars.startIndex
        var newIndex = newScalars.startIndex
        while oldIndex != oldScalars.endIndex, newIndex != newScalars.endIndex,
            oldScalars[oldIndex] == newScalars[newIndex]
        {
            oldScalars.formIndex(after: &oldIndex)
            newScalars.formIndex(after: &newIndex)
        }
        var deleteCount = 0
        var deleteUTF16Count = 0
        while oldIndex != oldScalars.endIndex {
            deleteCount += 1
            deleteUTF16Count += UTF16.width(oldScalars[oldIndex])
            oldScalars.formIndex(after: &oldIndex)
        }
        let insert = newIndex == newScalars.startIndex ? new : String(newScalars[newIndex...])
        return TextEdit(deleteCount: deleteCount, deleteUTF16Count: deleteUTF16Count, insert: insert)
    }

    /// The action for a key added to the token (ENG-R610): `passThrough` when the new display is the
    /// old one plus exactly the typed character, otherwise the minimal edit with the key swallowed
    /// (an empty edit swallows a key that changes nothing visible).
    package static func actionForKey(_ key: UInt8, from old: String, to new: String) -> KeyAction {
        let edit = edit(from: old, to: new)
        if edit.deleteCount == 0, isSingleScalar(edit.insert, equalTo: key) { return .passThrough }
        return .edit(edit, thenPassThrough: false)
    }

    /// The action for Backspace inside a token (ENG-R712): `passThrough` when the new display is the old
    /// one minus its last character (the app deletes it), otherwise the minimal edit with the
    /// Backspace swallowed.
    package static func actionForBackspace(from old: String, to new: String) -> KeyAction {
        let edit = edit(from: old, to: new)
        if edit.deleteCount == 1, edit.insert.isEmpty { return .passThrough }
        return .edit(edit, thenPassThrough: false)
    }

    @inline(__always)
    private static func isSingleScalar(_ text: String, equalTo key: UInt8) -> Bool {
        var scalars = text.unicodeScalars.makeIterator()
        guard let first = scalars.next(), first.value == UInt32(key) else { return false }
        return scalars.next() == nil
    }
}
