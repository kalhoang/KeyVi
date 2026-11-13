// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The status menu as an ordered list of entries (PRD-R11), so its order, conditional items and copy keys are
// tested without AppKit. `StatusItemController` maps each entry to one `NSMenuItem`.

public import AppModel

public enum MenuEntry: Sendable, Hashable {
    /// Item 1 (conditional): the status sentence; clickable when the line has an action.
    case status(StatusLine)
    /// The line's action, shown under the sentence ("Cấp quyền...", "Hiện 1Password", ...).
    case statusAction(StatusLine)
    /// Item 2: VI/EN radio pair with the toggle hotkey on the right.
    case mode(TypingMode, isSelected: Bool, hotkey: String)
    case separator
    /// Item 3: Telex/VNI radio pair.
    case method(TypingMethod, isSelected: Bool)
    /// Item 4 (conditional): "Với <App>" submenu with the four rules and "Báo lỗi với ứng dụng này...".
    case perApp(MenuModel.FrontmostAppMenu)
    /// Item 5.
    case macros, settings
    /// Item 6.
    case reportProblem
    case checkForUpdates(enabled: Bool)
    /// Item 7: opens About & Support (PRD-R57: the only in-menu donation entry; no badge, no counter).
    case donate
    /// Item 8.
    case quit

    static func entries(for model: MenuModel) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let line = model.statusLine {
            entries.append(.status(line))
            if line.actionLabelKey != nil { entries.append(.statusAction(line)) }
            entries.append(.separator)
        }
        entries += TypingMode.allCases.map { .mode($0, isSelected: $0 == model.mode, hotkey: model.toggleHotkeyDisplay) }
        entries.append(.separator)
        entries += TypingMethod.allCases.map { .method($0, isSelected: $0 == model.method) }
        if let app = model.frontmostApp { entries.append(.perApp(app)) }
        entries += [.separator, .macros, .settings]
        entries += [.separator, .reportProblem, .checkForUpdates(enabled: model.updateCheckEnabled)]
        entries += [.donate, .quit]
        return entries
    }

    /// Title key in the `Menu` table (status entries use the `Status` table through `StatusLine`).
    public var titleKey: MenuText? {
        switch self {
        case .status, .statusAction, .separator: nil
        case .mode(let mode, _, _): mode == .vietnamese ? .modeVietnamese : .modeEnglish
        case .method(let method, _): method == .telex ? .methodTelex : .methodVNI
        case .perApp: .perAppTitle
        case .macros: .macros
        case .settings: .settings
        case .reportProblem: .reportProblem
        case .checkForUpdates: .checkForUpdates
        case .donate: .donate
        case .quit: .quit
        }
    }

    /// VoiceOver hint key in the `Menu` table (PRD-R66).
    public var accessibilityHintKey: MenuText? {
        switch self {
        case .status, .statusAction: .statusHint
        case .separator: nil
        case .mode: .modeHint
        case .method: .methodHint
        case .perApp: .perAppHint
        case .macros: .macrosHint
        case .settings: .settingsHint
        case .reportProblem: .reportProblemHint
        case .checkForUpdates: .checkForUpdatesHint
        case .donate: .donateHint
        case .quit: .quitHint
        }
    }

    /// Key equivalent with Command (PRD-R11: Command+, for Settings, Command+Q for Quit).
    public var commandKeyEquivalent: String? {
        switch self {
        case .settings: ","
        case .quit: "q"
        default: nil
        }
    }
}

extension PerAppRule {
    /// PRD-R11 item 4 labels, in submenu order (`allCases`: remember, always English, always Vietnamese, ignore).
    public var menuTitleKey: MenuText {
        switch self {
        case .remember: .ruleRemember
        case .alwaysEnglish: .ruleAlwaysEnglish
        case .alwaysVietnamese: .ruleAlwaysVietnamese
        case .ignore: .ruleIgnore
        }
    }
}
