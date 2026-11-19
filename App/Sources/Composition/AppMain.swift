// SPDX-License-Identifier: GPL-3.0-or-later
//
// Entry point of the menu-bar app (LSUIElement, PLT-R201). It builds the composition root and forwards the
// application events to it; everything else lives in `AppEnvironment`. Workstream W2-A. Since 15/11/2026 (PRD-R28) it
// also installs the main menu and the window presence: a Dock icon and a place in Command+Tab while a window is open.

import AppKit
import ShellCore

@main
@MainActor
final class AppMain: NSObject, NSApplicationDelegate, WindowPresenceOwner {
    private var environment: AppEnvironment?
    private(set) var windowPresence: WindowPresenceController?
    private var mainMenu: MainMenuController?

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
        let presence = WindowPresenceController()
        presence.start()
        windowPresence = presence
        let menu = MainMenuController(
            language: environment.language, appName: environment.brand.displayName,
            showAbout: { [unowned environment] in environment.showAboutFromMainMenu() },
            showSettings: { [unowned environment] in environment.showSettingsFromMainMenu() })
        menu.install()
        mainMenu = menu
        environment.start()
    }

    /// A click on the Dock icon (PRD-R28): the app brings back a window left in the Dock, or opens Settings when
    /// none is open. AppKit's own reopen handling is never needed, since its flag also counts panels.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let windowPresence else { return true }
        if windowPresence.handleDockReopen() { environment?.showSettingsFromMainMenu() }
        return false
    }

    /// Quit waits for the settings flush (PLT-R1003, bounded); the reply comes from `AppEnvironment.terminate`
    /// through the main run loop (AppEnvironment+Quit.swift).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else { return .terminateNow }
        environment.terminate()
        return .terminateLater
    }

    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { environment?.handle(url: url) }
    }

    /// A menu-bar app keeps running when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
