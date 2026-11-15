// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main menu of PRD-R28 (amended 15/11/2026), shown while a window is open and the app is a regular app
// (`WindowPresenceController`): ShellCore's `MainMenuLayout` mapped to `NSMenuItem`s with the standard AppKit actions,
// rebuilt when the interface language changes (PRD-R63). Separate from the status menu (PRD-R11).

import AppKit
import Combine
import ShellCore

@MainActor
final class MainMenuController: NSObject {
    private let language: InterfaceLanguageModel
    private let appName: String
    private let showAbout: @MainActor () -> Void
    private let showSettings: @MainActor () -> Void
    private var languageObservation: AnyCancellable?

    init(
        language: InterfaceLanguageModel, appName: String, showAbout: @escaping @MainActor () -> Void,
        showSettings: @escaping @MainActor () -> Void
    ) {
        self.language = language
        self.appName = appName
        self.showAbout = showAbout
        self.showSettings = showSettings
    }

    func install() {
        rebuild()
        languageObservation = language.afterChange { [weak self] in self?.rebuild() }
    }

    private func rebuild() {
        let localizer = language.localizer
        let bar = NSMenu()
        for section in MainMenuLayout.sections {
            let title = section.title.map { localizer.string($0) } ?? appName
            let menu = NSMenu(title: title)
            for entry in section.entries {
                switch entry {
                case .separator: menu.addItem(.separator())
                case .item(let command): menu.addItem(item(command, localizer: localizer))
                }
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            bar.addItem(holder)
            if section.title == .window { NSApp.windowsMenu = menu }
        }
        NSApp.mainMenu = bar
    }

    private func item(_ command: MainMenuCommand, localizer: Localizer) -> NSMenuItem {
        let item = NSMenuItem(
            title: MainMenuLayout.title(of: command, localizer: localizer, appName: appName),
            action: Self.action(of: command), keyEquivalent: command.shortcut?.key ?? "")
        if let shortcut = command.shortcut {
            var modifiers: NSEvent.ModifierFlags = [.command]
            if shortcut.option { modifiers.insert(.option) }
            if shortcut.shift { modifiers.insert(.shift) }
            item.keyEquivalentModifierMask = modifiers
        }
        if command == .about || command == .settings { item.target = self }
        return item
    }

    /// The standard actions go up the responder chain (the field editor, the key window, the application).
    private static func action(of command: MainMenuCommand) -> Selector {
        switch command {
        case .about: #selector(about(_:))
        case .settings: #selector(settings(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: #selector(NSApplication.unhideAllApplications(_:))
        case .quit: #selector(NSApplication.terminate(_:))
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .minimize: #selector(NSWindow.performMiniaturize(_:))
        case .close: #selector(NSWindow.performClose(_:))
        case .bringAllToFront: #selector(NSApplication.arrangeInFront(_:))
        }
    }

    @objc private func about(_ sender: Any?) { showAbout() }
    @objc private func settings(_ sender: Any?) { showSettings() }
}
