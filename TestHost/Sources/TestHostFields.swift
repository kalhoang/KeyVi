// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 contract: each field exposes its current text to the runner through AX (`AXValue` of the element
// with this accessibility identifier). Web fields mirror their DOM value into a native read-only field through
// a WKScriptMessageHandler so AX readback works the same way (WebFields.swift). Workstream W2-E1.
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
    /// Second window (SecondWindow.swift): per-window rules, privacy canary strategies, restore hotkey.
    case secondTextField = "testhost.second.textField"
    case secondTextView = "testhost.second.textView"
    case secondPlainField = "testhost.second.plainField"
    /// Shows every Escape that reaches it as `<esc>` (PLT-R353).
    case escapeField = "testhost.second.escapeField"
}

/// Identifier of the button that clears every field of both windows (pressed by the harness before each
/// TestHost scenario, TestHostControls.resetFields).
let resetFieldsIdentifier = "testhost.resetFields"


@MainActor
final class TestHostWindowController: NSWindowController {
    private var access: [TestHostField: (get: () -> String, reset: () -> Void)] = [:]
    private var views: [TestHostField: NSView] = [:]
    let web = WebFieldsController()
    let secureInput = SecureInputHolder()
    /// Called by the Reset fields button; the app delegate also clears the second window.
    var onReset: (() -> Void)?

    required init?(coder: NSCoder) { nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TestHost"
        window.center()
        super.init(window: window)
        let layout = TestHostLayout()
        buildNativeFields(into: layout)
        buildWebFields(into: layout)
        layout.addRow("Secure input", secureInput.checkbox)
        layout.addRow("", resetButton())
        window.contentView = layout.contentView()
        window.initialFirstResponder = layout.firstField
        web.loadPage(named: WebFieldsController.pages[0])
    }

    private func buildNativeFields(into layout: TestHostLayout) {
        let textField = NSTextField(string: "")
        textField.placeholderString = "Type here"
        describe(textField, .nativeTextField, "Native text field", "Plain NSTextField.")
        access[.nativeTextField] = ({ textField.stringValue }, { textField.stringValue = "" })
        views[.nativeTextField] = textField
        layout.addRow("Native text field", textField)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        describe(textView, .nativeTextView, "Native text view", "Multi-line NSTextView.")
        access[.nativeTextView] = ({ textView.string }, { textView.string = "" })
        layout.addRow("Native text view", Self.scrolling(textView, height: 80))

        let addressBar = InlineCompletionTextView(
            identifier: TestHostField.addressBarWithCompletion.rawValue, label: "Simulated address bar",
            hint: "Completes from history inline and selects the suggested remainder.")
        access[.addressBarWithCompletion] = ({ addressBar.string }, { addressBar.replaceAll(with: "") })
        views[.addressBarWithCompletion] = addressBar
        layout.addRow("Address bar (inline completion)", Self.toolbar(addressBar.embedded()))

        let cell = SpreadsheetCellTextView(
            identifier: TestHostField.spreadsheetCell.rawValue, label: "Simulated spreadsheet cell",
            hint: "Loses keys while entering edit mode and autocompletes from its column.")
        let dropped = NSTextField(labelWithString: "Dropped keys: 0")
        dropped.setAccessibilityIdentifier("testhost.sim.sheetCell.dropped")
        cell.onDroppedKey = { dropped.stringValue = "Dropped keys: " + String($0) }
        access[.spreadsheetCell] = ({ cell.string }, { cell.replaceAll(with: "") })
        layout.addRow("Spreadsheet cell", cell.embedded())
        layout.addRow("", dropped)

        let password = ReadableSecureTextField(string: "")
        describe(password, .passwordField, "Password field", "Secure text field; text must arrive untransformed.")
        access[.passwordField] = ({ password.stringValue }, { password.stringValue = "" })
        layout.addRow("Password", password)
    }

    private func buildWebFields(into layout: TestHostLayout) {
        layout.addRow("Page", web.picker)
        web.webView.translatesAutoresizingMaskIntoConstraints = false
        web.webView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        layout.addRow("Web view", web.webView)
        let labels: [TestHostField: String] = [
            .webInput: "Web input (mirror)", .webTextarea: "Web textarea (mirror)",
            .webContentEditable: "Web contenteditable (mirror)",
        ]
        for field in WebFieldsController.mirroredFields {
            guard let mirror = web.mirrors[field] else { continue }
            access[field] = ({ [web] in web.text(of: field) }, { [web] in web.reset(field) })
            layout.addRow(labels[field] ?? field.rawValue, mirror)
        }
    }

    private func describe(_ view: NSView, _ field: TestHostField, _ label: String, _ hint: String) {
        view.setAccessibilityIdentifier(field.rawValue)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(hint)
    }

    private func resetButton() -> NSButton {
        let button = NSButton(title: "Reset fields", target: self, action: #selector(resetFields(_:)))
        button.setAccessibilityIdentifier(resetFieldsIdentifier)
        button.setAccessibilityLabel("Reset fields")
        button.setAccessibilityHelp("Clears every field of both windows before the next scenario.")
        return button
    }

    @objc private func resetFields(_ sender: Any?) {
        resetAll()
        onReset?()
    }

    /// Clears every field of this window, native and web.
    func resetAll() { access.values.forEach { $0.reset() } }

    /// Brings this window forward and focuses a native field (Window menu, Command+1 and Command+3).
    func focus(_ field: TestHostField) {
        guard let view = views[field] else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
    }

    static func scrolling(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        textView.autoresizingMask = [.width]
        return scroll
    }

    /// Wraps the address bar in an element with the toolbar role, like a browser's omnibox (rules match
    /// `ancestorRoles: ["AXToolbar"]`, 5.6).
    private static func toolbar(_ content: NSView) -> NSView {
        let container = NSView()
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.toolbar)
        container.setAccessibilityLabel("Simulated browser toolbar")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Clears a field before a scenario step.
    func reset(_ field: TestHostField) { access[field]?.reset() }

    /// Current text, as the runner would read it through AX.
    func text(of field: TestHostField) -> String { access[field]?.get() ?? "" }

    /// Opens a local page passed by the runner (`openURL` setup step with the TestHost target).
    func open(_ url: URL) { web.load(url) }
}
