// SPDX-License-Identifier: GPL-3.0-or-later
//
// Search panel of the test host (PLT-R389; Pa's items 7 and 9 of 2026-11-14: in Spotlight "tex" gave "teẽ" and
// "vieejt" gave "vieêệt", and on the second opening Escape became a restore). Window > Show Search Panel
// (Command+K) shows a non-activating panel whose search field completes inline like Spotlight's: after an insertion
// at the end, the remainder of a matching suggestion (case and diacritics ignored, so "viê" still matches) is
// appended and selected, so a Backspace that ignores the selection only removes the suggestion. Escape closes the
// panel and appends the query and `<esc>` to a transcript; the next opening starts with an empty query. The
// transcript and the current query are mirrored into the main window (`TestHostField.panelMirror`) for the runner.
// Profile `testhost-reproductions` gives the field the action of `launcher.spotlight` (overlay, axSelection, no
// restore hotkey). Labels are fixed English fixture text.

import AppKit

/// The panel's search field: Spotlight-like inline completion, Escape reported to the controller.
final class SearchPanelTextView: SingleLineTextView {
    /// Chosen so the scenario words get a suggestion on every key but the last: `vieejt` ("v" ... "việ" match
    /// "vien", "việt" does not) and `texxt` ("t", "te", "tẽ" match "teen", "tex" and "text" do not).
    var suggestions = ["vien.example", "teen.example"]
    var onEscape: (() -> Void)?
    var onChange: (() -> Void)?
    private var typedLength = 0

    /// The query without the selected suggestion.
    var query: String {
        let range = selectedRange()
        guard range.length > 0, range.location + range.length == (string as NSString).length else { return string }
        return (string as NSString).substring(to: range.location)
    }

    override func didChangeText() {
        super.didChangeText()
        let text = string
        let length = (text as NSString).length
        defer {
            typedLength = (string as NSString).length - selectedRange().length
            onChange?()
        }
        guard length > typedLength, selectedRange() == NSRange(location: length, length: 0),
            let remainder = TextCompletion.remainder(after: text, in: suggestions, ignoringDiacritics: true)
        else { return }
        textStorage?.append(NSAttributedString(string: remainder, attributes: typingAttributes))
        setSelectedRange(NSRange(location: length, length: (remainder as NSString).length))
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    // NSTextView maps Escape to `complete:` (the completion list); in this panel Escape closes, like Spotlight's.
    override func complete(_ sender: Any?) { onEscape?() }

    override func replaceAll(with text: String) {
        super.replaceAll(with: text)
        typedLength = (text as NSString).length
    }
}

@MainActor
final class SearchPanelController: NSObject {
    let mirror: MirrorTextField
    private let panel: NSPanel
    private let field = SearchPanelTextView(
        identifier: TestHostField.panelSearch.rawValue, label: "Search panel field",
        hint: "Completes inline like Spotlight; Escape closes the panel.")
    private var transcript = ""
    /// The window that was key before the panel opened gets the key focus back when it closes.
    private weak var previousKeyWindow: NSWindow?

    /// The owner sets `mirror.onFocusRequest` (an AX focus request on the mirror focuses the main window's text
    /// field, the app the panel opens over).
    override init() {
        mirror = MirrorTextField(string: "")
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 60),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        mirror.isEditable = false
        mirror.isSelectable = true
        mirror.setAccessibilityIdentifier(TestHostField.panelMirror.rawValue)
        mirror.setAccessibilityLabel("Search panel transcript (mirror)")
        mirror.setAccessibilityHelp(
            "Shows each closed search and the current query; focusing it focuses the text field.")
        panel.title = "TestHost search panel"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.contentView = field.embedded()
        panel.initialFirstResponder = field
        field.onEscape = { [weak self] in self?.close() }
        field.onChange = { [weak self] in self?.updateMirror() }
    }

    /// Window > Show Search Panel (Command+K): an empty query, the panel key without activating anything.
    func show() {
        guard !panel.isVisible else { return }
        previousKeyWindow = NSApp.keyWindow
        field.replaceAll(with: "")
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        updateMirror()
    }

    /// Escape: the query (without a selected suggestion) and `<esc>` go to the transcript, the panel closes and the
    /// previous window is key again.
    func close() {
        guard panel.isVisible else { return }
        transcript += field.query + EscapeMarkingTextView.marker
        field.replaceAll(with: "")
        panel.orderOut(nil)
        previousKeyWindow?.makeKeyAndOrderFront(nil)
        updateMirror()
    }

    /// Reset fields: hides the panel and clears the transcript.
    func reset() {
        panel.orderOut(nil)
        field.replaceAll(with: "")
        transcript = ""
        updateMirror()
    }

    private func updateMirror() {
        mirror.stringValue = transcript + (panel.isVisible ? field.string : "")
    }
}
