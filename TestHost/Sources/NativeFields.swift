// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Simulated native fields of the test host (QA-R10, 02-platform.md 4.3 and 6). Each reproduces one behaviour
// that breaks naive injection, deterministically and without accounts or network:
// - InlineCompletionTextView: browser address bar; after an insertion at the end, a matching suggestion's
//   remainder is appended and selected, so a backspace removes only the selection ("as" -> "aá" bug).
// - SpreadsheetCellTextView: cell editor; the first key enters edit mode and keys during the transition are
//   lost; column autocomplete selects the remainder of a matching value ("D"+"d" -> "DĐức" bug).
// - ReadableSecureTextField: password field whose text the runner can read back (PLT-R387 no-transformation).
// The local pages (TestHost/Resources/Pages/testhost.js) implement the same rules for real browsers.

import AppKit

/// Prefix matching shared by the simulated fields: case-insensitive for the address bar, also ignoring
/// Vietnamese diacritics (including đ/Đ, which have no Unicode decomposition) for the spreadsheet column.
enum TextCompletion {
    static func fold(_ text: String, diacritics: Bool) -> String {
        let lowered = text.lowercased()
        guard diacritics else { return lowered }
        return lowered.folding(options: [.diacriticInsensitive], locale: nil).replacingOccurrences(of: "đ", with: "d")
    }

    /// Remainder of the first suggestion that `typed` is a proper prefix of, in the suggestion's spelling.
    static func remainder(after typed: String, in suggestions: [String], ignoringDiacritics: Bool) -> String? {
        let key = fold(typed, diacritics: ignoringDiacritics)
        guard !key.isEmpty else { return nil }
        for suggestion in suggestions {
            let folded = fold(suggestion, diacritics: ignoringDiacritics)
            guard folded.count > key.count, folded.hasPrefix(key) else { continue }
            return String(suggestion.dropFirst(typed.count))
        }
        return nil
    }
}

/// Plain single-line text view (Return and Tab end editing) inside a bordered scroll view.
class SingleLineTextView: NSTextView {
    convenience init(identifier: String, label: String, hint: String) {
        self.init(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        isFieldEditor = true
        isRichText = false
        allowsUndo = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        textContainerInset = NSSize(width: 2, height: 3)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityHelp(hint)
        setAccessibilityRole(.textField)
    }

    /// The text view wrapped for layout, with a visible border and focus ring.
    func embedded() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = self
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = false
        scroll.focusRingType = .exterior
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 26).isActive = true
        autoresizingMask = [.width]
        return scroll
    }

    func replaceAll(with text: String) {
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
}

/// Browser address bar with inline autocomplete (4.3).
final class InlineCompletionTextView: SingleLineTextView {
    /// Bare host-like strings (no scheme), chosen so common Telex and VNI first keystrokes hit a suggestion.
    var suggestions = ["asia.example", "dd.example", "canh.example", "books.example", "co.example"]
    private var typedLength = 0

    override func didChangeText() {
        super.didChangeText()
        let text = string
        let length = (text as NSString).length
        defer { typedLength = (string as NSString).length - selectedRange().length }
        guard length > typedLength, selectedRange() == NSRange(location: length, length: 0),
            let remainder = TextCompletion.remainder(after: text, in: suggestions, ignoringDiacritics: false)
        else { return }
        completeWith(remainder, at: length)
    }

    func completeWith(_ remainder: String, at location: Int) {
        textStorage?.append(NSAttributedString(string: remainder, attributes: typingAttributes))
        setSelectedRange(NSRange(location: location, length: (remainder as NSString).length))
    }

    override func replaceAll(with text: String) {
        super.replaceAll(with: text)
        typedLength = (text as NSString).length
    }
}

/// Spreadsheet cell editor (section 6): edit-mode transition plus column autocomplete.
final class SpreadsheetCellTextView: SingleLineTextView {
    /// Keys arriving this soon after the key that entered edit mode are lost, like a cell editor that is not
    /// ready yet. Longer than the 5 ms burst interval, shorter than a normal keystroke gap.
    static let transitionSeconds: TimeInterval = 0.020

    var column = ["Đức", "Dũng", "Nguyễn", "Hà Nội"]
    private(set) var droppedKeys = 0
    private var editStartedAt: TimeInterval?
    private var typedLength = 0
    var onDroppedKey: ((Int) -> Void)?

    override func becomeFirstResponder() -> Bool {
        editStartedAt = nil  // focusing the cell returns it to navigation mode
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard let start = editStartedAt else {
            editStartedAt = event.timestamp
            super.keyDown(with: event)
            return
        }
        if event.timestamp - start < Self.transitionSeconds {
            droppedKeys += 1
            onDroppedKey?(droppedKeys)
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        let text = string
        let length = (text as NSString).length
        defer { typedLength = (string as NSString).length - selectedRange().length }
        guard length > typedLength, selectedRange() == NSRange(location: length, length: 0),
            let remainder = TextCompletion.remainder(after: text, in: column, ignoringDiacritics: true)
        else { return }
        textStorage?.append(NSAttributedString(string: remainder, attributes: typingAttributes))
        setSelectedRange(NSRange(location: length, length: (remainder as NSString).length))
    }

    override func replaceAll(with text: String) {
        super.replaceAll(with: text)
        typedLength = (text as NSString).length
        editStartedAt = nil
        droppedKeys = 0
        onDroppedKey?(0)
    }
}

/// `NSSecureTextField` that still answers `AXValue` with its text, so the runner can assert that a password
/// field received the raw keys untransformed (PLT-R387). Test fixture only: never do this in a product.
final class ReadableSecureTextField: NSSecureTextField {
    override func accessibilityValue() -> String? { stringValue }
}
