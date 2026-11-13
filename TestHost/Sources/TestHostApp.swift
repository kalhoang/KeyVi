// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 test host. SKELETON: one window with the native text field. Workstream W2-E1 adds the text view, the
// WKWebView page (input, textarea, contenteditable), the simulated address bar with inline autocomplete, the
// simulated spreadsheet cell editor and the password field, each exposing its text through AX identifiers.

import AppKit

@main
@MainActor
final class TestHostApp: NSObject, NSApplicationDelegate {
    private var windowController: TestHostWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = TestHostApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TestHostWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
