// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 contract: each field exposes its current text to the runner through AX (`AXValue` of the element
// with this accessibility identifier). Web fields mirror their DOM value into a hidden native field through a
// WKScriptMessageHandler so AX readback works the same way. Workstream W2-E1 (was W1-H).
// The window title and labels are fixed English test-fixture text, not product copy.

import AppKit

enum TestHostField: String, CaseIterable {
    case nativeTextField = "testhost.native.textField"
    case nativeTextView = "testhost.native.textView"
    case webInput = "testhost.web.input"
    case webTextarea = "testhost.web.textarea"
    case webContentEditable = "testhost.web.contentEditable"
    /// Selects the suggested remainder after the caret like a browser address bar (4.3).
    case addressBarWithCompletion = "testhost.sim.addressBar"
    /// Drops the first event after entering edit mode and autocompletes from a column (Sheets/Excel, 6).
    case spreadsheetCell = "testhost.sim.sheetCell"
    /// `NSSecureTextField`: asserts no transformation (PLT-R387).
    case passwordField = "testhost.native.password"
}

@MainActor
final class TestHostWindowController: NSWindowController {
    private var fields: [TestHostField: NSTextField] = [:]

    required init?(coder: NSCoder) { nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TestHost"
        window.center()
        super.init(window: window)

        let label = NSTextField(labelWithString: "Native text field")
        let field = NSTextField(string: "")
        field.placeholderString = "Type here"
        field.setAccessibilityIdentifier(TestHostField.nativeTextField.rawValue)
        fields[.nativeTextField] = field

        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
        window.initialFirstResponder = field
    }

    /// Clears a field before a scenario step. Fields the skeleton does not build yet are ignored.
    func reset(_ field: TestHostField) { fields[field]?.stringValue = "" }

    /// Current text, as the runner would read it through AX. Empty for fields not built yet.
    func text(of field: TestHostField) -> String { fields[field]?.stringValue ?? "" }
}
