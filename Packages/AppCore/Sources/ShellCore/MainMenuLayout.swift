// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main menu shown while the app is a regular app (PRD-R28 amended 15/11/2026, `AppPresence`): the app menu, Edit
// and Window, with the standard macOS shortcuts, so Command+, Command+H, Command+Q, the Edit commands in text fields
// and Command+M and Command+W work in every window. The App target maps each command to an `NSMenuItem` and its
// AppKit action. Copy comes from the Menu table, the app name as a format argument (PRD-R62); it is separate from
// the status menu (PRD-R11, `MenuEntry`).

/// `Menu` table keys of the main menu. Settings, Quit and Close reuse the status menu's and the common words.
public enum MainMenuText: String, LocalizationKey {
    public static var table: StringTable { .menu }

    case about = "mainMenu.app.about"
    case hide = "mainMenu.app.hide"
    case hideOthers = "mainMenu.app.hideOthers"
    case showAll = "mainMenu.app.showAll"
    case edit = "mainMenu.edit"
    case undo = "mainMenu.edit.undo"
    case redo = "mainMenu.edit.redo"
    case cut = "mainMenu.edit.cut"
    case copy = "mainMenu.edit.copy"
    case paste = "mainMenu.edit.paste"
    case selectAll = "mainMenu.edit.selectAll"
    case window = "mainMenu.window"
    case minimize = "mainMenu.window.minimize"
    case bringAllToFront = "mainMenu.window.bringAllToFront"
}

public enum MainMenuCommand: String, Sendable, Hashable, CaseIterable {
    case about, settings, hide, hideOthers, showAll, quit
    case undo, redo, cut, copy, paste, selectAll
    case minimize, close, bringAllToFront

    /// The standard macOS shortcut; nil for the commands that have none.
    public var shortcut: MainMenuShortcut? {
        switch self {
        case .about, .showAll, .bringAllToFront: nil
        case .settings: .command(",")
        case .hide: .command("h")
        case .hideOthers: MainMenuShortcut(key: "h", option: true)
        case .quit: .command("q")
        case .undo: .command("z")
        case .redo: MainMenuShortcut(key: "z", shift: true)
        case .cut: .command("x")
        case .copy: .command("c")
        case .paste: .command("v")
        case .selectAll: .command("a")
        case .minimize: .command("m")
        case .close: .command("w")
        }
    }
}

/// A key equivalent: always with Command, optionally with Option or Shift.
public struct MainMenuShortcut: Sendable, Hashable {
    public var key: String
    public var option: Bool
    public var shift: Bool

    public init(key: String, option: Bool = false, shift: Bool = false) {
        self.key = key
        self.option = option
        self.shift = shift
    }

    public static func command(_ key: String) -> MainMenuShortcut { MainMenuShortcut(key: key) }
}

public enum MainMenuEntry: Sendable, Hashable {
    case item(MainMenuCommand)
    case separator

    public var command: MainMenuCommand? {
        if case .item(let command) = self { return command }
        return nil
    }
}

public struct MainMenuSection: Sendable, Hashable {
    /// Nil for the app menu, whose title macOS takes from the bundle.
    public var title: MainMenuText?
    public var entries: [MainMenuEntry]
}

public enum MainMenuLayout {
    public static let sections: [MainMenuSection] = [
        MainMenuSection(
            title: nil,
            entries: [
                .item(.about), .separator, .item(.settings), .separator, .item(.hide), .item(.hideOthers),
                .item(.showAll), .separator, .item(.quit),
            ]),
        MainMenuSection(
            title: .edit,
            entries: [
                .item(.undo), .item(.redo), .separator, .item(.cut), .item(.copy), .item(.paste), .item(.selectAll),
            ]),
        MainMenuSection(
            title: .window, entries: [.item(.minimize), .item(.close), .separator, .item(.bringAllToFront)]),
    ]

    public static func title(of command: MainMenuCommand, localizer: Localizer, appName: String) -> String {
        switch command {
        case .about: localizer.format(MainMenuText.about, appName)
        case .settings: localizer.string(MenuText.settings)
        case .hide: localizer.format(MainMenuText.hide, appName)
        case .hideOthers: localizer.string(MainMenuText.hideOthers)
        case .showAll: localizer.string(MainMenuText.showAll)
        case .quit: localizer.format(MenuText.quit, appName)
        case .undo: localizer.string(MainMenuText.undo)
        case .redo: localizer.string(MainMenuText.redo)
        case .cut: localizer.string(MainMenuText.cut)
        case .copy: localizer.string(MainMenuText.copy)
        case .paste: localizer.string(MainMenuText.paste)
        case .selectAll: localizer.string(MainMenuText.selectAll)
        case .minimize: localizer.string(MainMenuText.minimize)
        case .close: localizer.string(CommonText.close)
        case .bringAllToFront: localizer.string(MainMenuText.bringAllToFront)
        }
    }
}
