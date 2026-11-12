// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 test host. SKELETON: workstream W1-H adds the native text field, text view, WKWebView page
// (input, textarea, contenteditable), simulated address bar with inline autocomplete and simulated spreadsheet
// cell editor, each exposing its text to the runner through AX identifiers.

import AppKit

@main
@MainActor
final class TestHostApp: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = TestHostApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
