// SPDX-License-Identifier: GPL-3.0-or-later
//
// Layout of the Settings window in the style of macOS System Settings (Pa, 2026-11-14, feedback item 6; PRD-R24):
// a sidebar with the seven panes, each with an SF Symbol on a small coloured tile, and grouped sections on the right
// where each setting is a row with its title and one-line explanation (PRD-R25) on the left and its control on the
// right. The App target draws it; the rules that can be checked without drawing live here.

import AppModel
import CompatRules

/// Decorative tile colour behind a pane's symbol in the sidebar. The pane's name is always next to the tile, so the
/// colour carries no information of its own (PRD-R67).
public enum SettingsPaneTint: String, Sendable, Hashable, CaseIterable {
    case gray, blue, indigo, orange, green, red, brown
}

extension SettingsPaneKind {
    /// SF Symbol on the pane's tile; every symbol exists from macOS 11 (ADR 0315: the floor is macOS 12).
    public var sidebarSymbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .typing: "keyboard"
        case .apps: "square.grid.2x2.fill"
        case .macros: "text.badge.plus"
        case .about: SettingsSymbol.infoFill
        case .support: "lifepreserver.fill"
        case .licences: "c.circle.fill"
        }
    }

    public var sidebarTint: SettingsPaneTint {
        switch self {
        case .general: .gray
        case .typing: .blue
        case .apps: .indigo
        case .macros: .orange
        case .about: .green
        case .support: .red
        case .licences: .brown
        }
    }

    /// Command+1 to Command+7 select the panes in sidebar order (PRD-R67 keyboard navigation).
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public init?(shortcutNumber: Int) {
        let panes = Self.allCases
        guard (1...panes.count).contains(shortcutNumber) else { return nil }
        self = panes[panes.index(panes.startIndex, offsetBy: shortcutNumber - 1)]
    }

    /// The pane for a key event pressed with Command only, from its characters ignoring modifiers: one ASCII digit
    /// from 1 to 7.
    public static func forShortcut(characters: String?) -> SettingsPaneKind? {
        guard let characters, characters.count == 1, let digit = characters.first, digit.isASCII,
            let number = digit.wholeNumberValue
        else { return nil }
        return SettingsPaneKind(shortcutNumber: number)
    }

    /// The pane for a key on the number row by its virtual key code (kVK_ANSI_1 to kVK_ANSI_7), for layouts whose
    /// number row does not type digits without Shift, such as French AZERTY ("&" on the 1 key).
    public static func forShortcut(keyCode: UInt16?) -> SettingsPaneKind? {
        guard let keyCode, let number = numberRowKeyCodes[keyCode] else { return nil }
        return SettingsPaneKind(shortcutNumber: number)
    }

    /// The pane for a key equivalent: Command alone (caps lock and the keypad bit aside) with a digit from 1 to 7,
    /// or, when the characters are not a digit, the number row key from 1 to 7 like other Mac apps' Command+digit
    /// shortcuts. `modifierFlags` carries the bits NSEvent.ModifierFlags and CGEventFlags share.
    public static func forKeyEquivalent(
        characters: String?, keyCode: UInt16? = nil, modifierFlags: UInt64
    ) -> SettingsPaneKind? {
        guard modifierFlags & ShortcutModifier.significant == ShortcutModifier.command else { return nil }
        return forShortcut(characters: characters) ?? forShortcut(keyCode: keyCode)
    }

    /// Carbon `kVK_ANSI_1` to `kVK_ANSI_7` (Events.h): the keys, not the characters they type.
    private static let numberRowKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7]
}

/// Modifier bits that decide whether a key is a pane shortcut.
private enum ShortcutModifier {
    static let shift: UInt64 = 1 << 17
    static let control: UInt64 = 1 << 18
    static let option: UInt64 = 1 << 19
    static let command: UInt64 = 1 << 20
    static let function: UInt64 = 1 << 23
    static let significant = shift | control | option | command | function
}

/// A grouped section of a pane: an optional header and the settings it holds, in display order.
public struct SettingsSection: Sendable, Hashable {
    public var header: CatalogText?
    public var items: [SettingItem]

    public init(header: CatalogText?, items: [SettingItem]) {
        self.header = header
        self.items = items
    }

    /// The rows of the section: one setting each, except the two ENG-R860 word lists, which share one row side by
    /// side so the Typing pane fits its window without scrolling (PRD-R24 acceptance).
    public var rows: [[SettingItem]] {
        var result: [[SettingItem]] = []
        for item in items {
            if item == .keepVietnamese, result.last == [.keepAsTyped] {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result
    }
}

extension SettingsCatalog {
    /// The grouped sections of `pane`, outside the Advanced disclosure. They keep the PRD-R24 order of
    /// `items(in:advanced: false)`; the Apps pane is a list, not settings.
    public static func sections(in pane: SettingsPaneKind) -> [SettingsSection] {
        switch pane {
        case .general:
            [
                SettingsSection(header: CatalogText(SettingsText.sectionStartup), items: [.openAtLogin]),
                SettingsSection(
                    header: CatalogText(SettingsText.sectionSwitching),
                    items: [.toggleHotkey, .rememberPerApp, .switchIndicator]),
                SettingsSection(header: CatalogText(SettingsText.sectionLanguage), items: [.interfaceLanguage]),
            ]
        case .typing:
            [
                SettingsSection(
                    header: CatalogText(SettingsText.sectionVietnamese), items: [.typingMethod, .tonePlacement]),
                SettingsSection(
                    header: CatalogText(SettingsText.sectionEnglish),
                    items: [.englishRestore, .keepAsTyped, .keepVietnamese, .learnCollisionChoices]),
            ]
        case .apps: []
        case .macros: [SettingsSection(header: nil, items: [.macrosEnabled])]
        case .about:
            [
                SettingsSection(
                    header: CatalogText(SupportText.updatesTitle),
                    items: [.updateChannel, .automaticallyCheckForUpdates, .automaticallyInstallUpdates])
            ]
        case .support, .licences: []
        }
    }
}

/// Window sizes, in points, like System Settings: about 715 x 470 at the least, resizable; the default opens General
/// and Typing without scrolling on a 13-inch display at its default scaling, 1440 x 900 points (PRD-R24 acceptance).
/// The content runs under the transparent title bar, so these are the whole window's sizes. The size and position
/// are remembered (PRD-R28).
public enum SettingsWindowLayout {
    public static let minimumWidth = 715.0
    public static let minimumHeight = 470.0
    public static let defaultWidth = 780.0
    public static let defaultHeight = 768.0
    /// Fixed: the sidebar does not collapse or resize, like System Settings.
    public static let sidebarWidth = 190.0
    /// Side insets of the Apps and Macros panes, a little narrower than the grouped sections' so the lists get room.
    public static let listPaneInset = 12.0
    /// Width of the Apps and Macros lists at the window's minimum width (sidebar, its 1 pt divider and insets aside).
    public static var minimumListWidth: Double { minimumWidth - sidebarWidth - 1 - 2 * listPaneInset }
}

/// Columns of the Apps table (PRD-R34). The rule, remembered-mode and status columns are as wide as their longest
/// value in the interface language or their header, so none of them truncates; the app name column, the one a user
/// reads first, takes the rest of the width and every extra point of a wider window (Pa, 2026-11-14, feedback
/// item 6).
public enum AppsTableLayout {
    /// The fonts the table uses: the body font for names, modes and statuses; the small one for the rule pop-up
    /// (small control size) and the column headers.
    public enum TextStyle: Sendable { case body, small }

    public struct FixedColumns: Sendable, Equatable {
        public var rule: Double
        public var remembered: Double
        public var status: Double

        public var total: Double { rule + remembered + status }
    }

    /// The borderless rule pop-up's chevron and the gap before it.
    public static let ruleAccessoryWidth = 11.0
    /// The status symbol and the gap before its label (PRD-R67: symbol plus text).
    public static let statusAccessoryWidth = 22.0
    /// The app column never gets narrower than this: the icon and a few letters, the full name on hover.
    public static let appColumnMinimum = 80.0
    /// The header cell's padding around its title (the header uses the small font).
    public static let headerPadding = 10.0
    /// What the inset table style adds around the four columns: the 17 pt gap after each column and the row insets
    /// on both sides (4 x 17 + 8, measured on the snapshot images).
    public static let tableChrome = 76.0

    /// Widths of the three fixed columns for `localizer`'s language; `measure` returns a text's width in points in
    /// a style. Widths are rounded up to whole points.
    public static func fixedColumns(
        localizer: Localizer, measure: (String, TextStyle) -> Double
    ) -> FixedColumns {
        func width(_ header: AppsText, _ values: [AppsText], _ style: TextStyle, accessory: Double) -> Double {
            let longest = values.map { measure(localizer.string($0), style) }.max() ?? 0
            return max(measure(localizer.string(header), .small) + headerPadding, longest + accessory).rounded(.up)
        }
        return FixedColumns(
            rule: width(.columnRule, PerAppRule.allCases.map(\.appsTitle), .small, accessory: ruleAccessoryWidth),
            remembered: width(.columnRemembered, [.modeVietnamese, .modeEnglish, .modeNone], .body, accessory: 0),
            status: width(
                .columnStatus, MatrixStatus.allCases.map(\.appsTitle), .body, accessory: statusAccessoryWidth))
    }

    /// Width of the app column in a list `listWidth` points wide.
    public static func appColumnWidth(listWidth: Double, fixed: FixedColumns) -> Double {
        max(appColumnMinimum, (listWidth - tableChrome - fixed.total).rounded(.down))
    }
}
