// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Entry point of the menu-bar app (LSUIElement, PLT-R201). SKELETON: shows the bootstrap status item only; the
// composition root (`AppEnvironment`) is built by workstream W2-A (docs/architecture/contracts.md "AppShell").

import AppKit
import ShellCore

@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate {
    private var bootstrap: BootstrapStatusItem?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppMain()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // W2-A: LaunchGuard -> AppLocationCheck -> LegacyStorageMigrator -> SettingsStore.load -> RulesLoader
        // -> InputHostController -> StatusItemController -> Onboarding (first launch) -> UpdaterController.
        bootstrap = BootstrapStatusItem(brand: Brand.from(.main), strings: BootstrapStrings(languageCode: "vi"))
    }
}
