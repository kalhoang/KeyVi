// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Development skeleton of the menu bar presence (PRD-R9): a template glyph, a status line and Quit. It exists so
// the App target launches without any unimplemented contract. Workstream W1-G replaces it with
// `StatusItemController`; W2-A then removes this file from the launch path.

import AppKit
import ShellCore

@MainActor
final class BootstrapStatusItem {
    private let statusItem: NSStatusItem

    init(brand: Brand, strings: BootstrapStrings) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusGlyph.image(for: .notWorking)
            button.setAccessibilityLabel(strings.format("skeleton.statusItem.accessibilityLabel", brand.displayName))
        }
        let menu = NSMenu()
        let status = NSMenuItem(title: strings.string("skeleton.statusLine"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: strings.format("menu.quit", brand.displayName),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

/// Looks strings up in one language's `.lproj` regardless of the process language (ADR 0310). The skeleton
/// uses the default interface language (Vietnamese); ShellCore's `Localizer` (W1-G) replaces this.
struct BootstrapStrings {
    private let bundle: Bundle

    init(languageCode: String, in main: Bundle = .main) {
        bundle = main.path(forResource: languageCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? main
    }

    func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func format(_ key: String, _ argument: String) -> String {
        String(format: string(key), argument)
    }
}
