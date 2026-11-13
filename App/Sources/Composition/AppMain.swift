// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Entry point of the menu-bar app (LSUIElement, PLT-R201). It builds the composition root and forwards the
// application events to it; everything else lives in `AppEnvironment`. Workstream W2-A.

import AppKit
import ShellCore

@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppMain()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment(bundle: .main)
        self.environment = environment
        environment.start()
    }

    /// Quit waits for the settings flush (PLT-R1003); the reply comes from `AppEnvironment.terminate`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        environment.terminate { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { environment?.handle(url: url) }
    }

    /// A menu-bar app keeps running when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
