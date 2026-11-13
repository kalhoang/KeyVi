// SPDX-License-Identifier: GPL-3.0-or-later
//
// Second test-host window (QA-R11 "per-app rule switching between two host windows", privacy canary strategies,
// restore hotkey). Its fields have their own accessibility identifiers, so an app profile can give one of them a
// different rule (compat/scenarios/profiles) while the main window keeps the default; Window menu shortcuts move the
// focus between the windows from inside a key script. Labels are fixed English fixture text.

import AppKit

/// Single-line field that shows every Escape reaching it as the text `<esc>` (PLT-R353: a bound restore hotkey is
/// consumed on the first press and passes through on the second). Escape would otherwise open NSTextView's
/// completion list.
final class EscapeMarkingTextView: SingleLineTextView {
    static let marker = "<esc>"

    override func cancelOperation(_ sender: Any?) { insertText(Self.marker, replacementRange: selectedRange()) }
    override func complete(_ sender: Any?) { insertText(Self.marker, replacementRange: selectedRange()) }
}

@MainActor
final class TestHostSecondWindowController: NSWindowController {
    private var access: [TestHostField: (view: NSView, get: () -> String, reset: () -> Void)] = [:]

    required init?(coder: NSCoder) { nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TestHost second window"
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: 860))
        super.init(window: window)
        let layout = TestHostLayout()
        buildFields(into: layout)
        window.contentView = layout.contentView()
        window.initialFirstResponder = layout.firstField
    }

    private func buildFields(into layout: TestHostLayout) {
        let textField = NSTextField(string: "")
        describe(textField, .secondTextField, "Second window text field", "Plain NSTextField of the second window.")
        access[.secondTextField] = (textField, { textField.stringValue }, { textField.stringValue = "" })
        layout.addRow("Text field", textField)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        describe(textView, .secondTextView, "Second window text view", "Multi-line NSTextView of the second window.")
        access[.secondTextView] = (textView, { textView.string }, { textView.string = "" })
        layout.addRow("Text view", TestHostWindowController.scrolling(textView, height: 60))

        let plain = SingleLineTextView(
            identifier: TestHostField.secondPlainField.rawValue, label: "Second window plain field",
            hint: "Single-line NSTextView of the second window.")
        access[.secondPlainField] = (plain, { plain.string }, { plain.replaceAll(with: "") })
        layout.addRow("Plain field", plain.embedded())

        let escape = EscapeMarkingTextView(
            identifier: TestHostField.escapeField.rawValue, label: "Escape field",
            hint: "Shows each Escape key that reaches it as the text <esc>.")
        access[.escapeField] = (escape, { escape.string }, { escape.replaceAll(with: "") })
        layout.addRow("Escape field", escape.embedded())
    }

    private func describe(_ view: NSView, _ field: TestHostField, _ label: String, _ hint: String) {
        view.setAccessibilityIdentifier(field.rawValue)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(hint)
    }

    var fields: [TestHostField] { Array(access.keys) }

    func text(of field: TestHostField) -> String { access[field]?.get() ?? "" }

    func resetAll() {
        for field in access.values { field.reset() }
    }

    /// Brings this window forward and focuses `field` (Window menu, Command+2).
    func focus(_ field: TestHostField) {
        guard let view = access[field]?.view else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }
}
