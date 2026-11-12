// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Entry point of the menu-bar app (LSUIElement, PLT-R201). SKELETON: the composition root (AppEnvironment)
// is built by workstream W2-A; see docs/architecture/contracts.md "AppShell".

import AppKit

@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppMain()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // W2-A: LaunchGuard -> AppLocationCheck -> SettingsStore.load -> RulesLoader -> InputHostController
        // -> StatusItemController -> Onboarding (first launch) -> UpdaterController.
    }
}
