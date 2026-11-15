// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R28 (amended 15/11/2026): while a window is open the app is a regular app, and the menu bar shows its standard
// menus, so the usual shortcuts work in Settings and the other windows: Command+, Command+H, Command+Q, the Edit
// commands in text fields (the macro editor) and Command+M and Command+W. Copy comes from the Menu table with the
// app name as a format argument (PRD-R62).

import AppModel
import Testing

@testable import ShellCore

@Suite struct MainMenuLayoutTests {
    @Test func theMenusAreTheAppEditAndWindowMenusInThatOrder() {
        #expect(MainMenuLayout.sections.map(\.title) == [nil, .edit, .window])
        let commands = MainMenuLayout.sections.flatMap(\.entries).compactMap(\.command)
        #expect(commands.count == MainMenuCommand.allCases.count)
        #expect(Set(commands) == Set(MainMenuCommand.allCases))
    }

    @Test func everyCommandHasTheStandardShortcut() {
        let expected: [MainMenuCommand: MainMenuShortcut?] = [
            .about: nil, .settings: .command(","), .hide: .command("h"),
            .hideOthers: MainMenuShortcut(key: "h", option: true), .showAll: nil, .quit: .command("q"),
            .undo: .command("z"), .redo: MainMenuShortcut(key: "z", shift: true), .cut: .command("x"),
            .copy: .command("c"), .paste: .command("v"), .selectAll: .command("a"), .minimize: .command("m"),
            .close: .command("w"), .bringAllToFront: nil,
        ]
        for command in MainMenuCommand.allCases {
            #expect(command.shortcut == expected[command] ?? nil, "\(command)")
        }
    }

    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func titlesComeFromTheMenuTableWithTheAppName(_ language: InterfaceLanguage) throws {
        let app = try TemporaryAppBundle(catalogs: [.menu, .common])
        let localizer = Localizer(language: language, appBundle: app.bundle)
        for command in MainMenuCommand.allCases {
            let title = MainMenuLayout.title(of: command, localizer: localizer, appName: "SampleApp")
            #expect(!title.isEmpty && !title.contains("mainMenu.") && !title.contains("%@"), "\(command): \(title)")
        }
        for command in [MainMenuCommand.about, .hide, .quit] {
            #expect(MainMenuLayout.title(of: command, localizer: localizer, appName: "SampleApp").contains("SampleApp"))
        }
        for section in MainMenuLayout.sections {
            guard let title = section.title else { continue }
            #expect(!localizer.string(title).isEmpty && !localizer.string(title).contains("mainMenu."))
        }
        let vietnamese = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(MainMenuLayout.title(of: .copy, localizer: vietnamese, appName: "SampleApp") == "Sao chép")
        #expect(MainMenuLayout.title(of: .settings, localizer: vietnamese, appName: "SampleApp") == "Cài đặt...")
    }
}
