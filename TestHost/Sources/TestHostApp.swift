// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 test host: one window with every TestHostField (native text field and text view, WKWebView page with
// input, textarea and contenteditable, simulated address bar, simulated spreadsheet cell, password field), each
// exposing its text through AX identifiers. Started only by the self-hosted runner (QA-R12); never shipped.

import AppKit

@main
@MainActor
final class TestHostApp: NSObject, NSApplicationDelegate {
    private var windowController: TestHostWindowController?
    /// A page AppKit delivered before the window existed (launch by document: `application(_:open:)` runs before
    /// `applicationDidFinishLaunching`).
    private var pendingPage: URL?

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
        if let pendingPage {
            controller.open(pendingPage)
            self.pendingPage = nil
        }
        NSApp.activate()
    }

    /// `openURL` setup steps open a local page with this app; only `file:` .html pages are loaded.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL && $0.pathExtension == "html" }) else { return }
        guard let windowController else {
            pendingPage = url
            return
        }
        windowController.open(url)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.secureInput.setHolding(false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
