// SPDX-License-Identifier: GPL-3.0-or-later
//
// QA-R10 test host: one window with every TestHostField (native text field and text view, WKWebView page with
// input, textarea and contenteditable, simulated address bar, simulated spreadsheet cell, password field), each
// exposing its text through AX identifiers, plus a second window for per-window rules (QA-R11) and a Window menu
// whose shortcuts move the focus (Command+1, 2, 3). Started only by the self-hosted runner (QA-R12); never shipped.

import AppKit

@main
@MainActor
final class TestHostApp: NSObject, NSApplicationDelegate {
    private var windowController: TestHostWindowController?
    private let secondWindow = TestHostSecondWindowController()
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
        controller.onReset = { [secondWindow] in secondWindow.resetAll() }
        NSApp.mainMenu = TestHostMenu.make(target: self)
        secondWindow.showWindow(nil)
        controller.showWindow(nil)
        windowController = controller
        if let pendingPage {
            controller.open(pendingPage)
            self.pendingPage = nil
        }
        // `activate()` exists from macOS 14 only (ADR 0315: the floor is macOS 12).
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
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

    // MARK: Window menu (focus changes inside a key script, QA-R11 per-window rules, T6 workload)

    @objc func focusMainField(_ sender: Any?) { windowController?.focus(.nativeTextField) }
    @objc func focusSecondWindowField(_ sender: Any?) { secondWindow.focus(.secondTextField) }
    @objc func focusAddressBar(_ sender: Any?) { windowController?.focus(.addressBarWithCompletion) }

    // MARK: Focus moved by a shortcut without an app activation (PLT-R389, PLT-R340 late focus change)

    /// File > Save… (Command+S): a save sheet on the second window, its name field focused (SaveSheet.swift).
    @objc func showSaveSheet(_ sender: Any?) { secondWindow.showSaveSheet() }
    /// Window > Show Search Panel (Command+K): a non-activating panel like Spotlight's (SearchPanel.swift).
    @objc func showSearchPanel(_ sender: Any?) { windowController?.searchPanel.show() }
}

/// Main menu: Quit, File > Save…, the standard Edit menu and the Window menu's focus shortcuts and search panel.
/// Titles are fixed English fixture text.
@MainActor
enum TestHostMenu {
    static func make(target: TestHostApp) -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(
            NSMenuItem(title: "Quit TestHost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let fileMenu = NSMenu(title: "File")
        let save = NSMenuItem(title: "Save…", action: #selector(TestHostApp.showSaveSheet(_:)), keyEquivalent: "s")
        save.target = target
        fileMenu.addItem(save)
        let windowMenu = NSMenu(title: "Window")
        for (title, action, key) in [
            ("Focus Main Field", #selector(TestHostApp.focusMainField(_:)), "1"),
            ("Focus Second Window Field", #selector(TestHostApp.focusSecondWindowField(_:)), "2"),
            ("Focus Address Bar", #selector(TestHostApp.focusAddressBar(_:)), "3"),
            ("Show Search Panel", #selector(TestHostApp.showSearchPanel(_:)), "k"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            windowMenu.addItem(item)
        }
        for menu in [appMenu, fileMenu, editMenu(), windowMenu] {
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        return main
    }

    /// The standard Edit menu, sent to the first responder like in every real app. AppKit turns Command+V into
    /// `paste:` only through this key equivalent, so without it the `paste` strategy's synthetic Command+V (PLT-R461
    /// step 3) reached no field (`testhost.privacyCanary.paste`, integration-suite.md section 10.5).
    static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        return menu
    }
}
