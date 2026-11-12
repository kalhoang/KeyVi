// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 contract: each field exposes its current text to the runner through AX (`AXValue` of the element
// with this accessibility identifier). Web fields mirror their DOM value into a hidden native field through a
// WKScriptMessageHandler so AX readback works the same way. Workstream W1-H.

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
    required init?(coder: NSCoder) { fatalError("not used") }

    init() { fatalError("W1-H") }
    func reset(_ field: TestHostField) { fatalError("W1-H") }
    func text(of field: TestHostField) -> String { fatalError("W1-H") }
}
