// SPDX-License-Identifier: GPL-3.0-or-later
//
// Layout of the Settings window in the style of macOS System Settings (Pa, 2026-11-14, feedback item 6; PRD-R24):
// a sidebar with the five panes, each with an SF Symbol on a small coloured tile, and grouped sections on the right
// where each setting is a row with its title and one-line explanation (PRD-R25) on the left and its control on the
// right. The App target draws it; the rules that can be checked without drawing live here.

/// Decorative tile colour behind a pane's symbol in the sidebar. The pane's name is always next to the tile, so the
/// colour carries no information of its own (PRD-R67).
public enum SettingsPaneTint: String, Sendable, Hashable, CaseIterable {
    case gray, blue, indigo, orange, green
}

extension SettingsPaneKind {
    /// SF Symbol on the pane's tile; every symbol exists from macOS 11 (ADR 0315: the floor is macOS 12).
    public var sidebarSymbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .typing: "keyboard"
        case .apps: "square.grid.2x2.fill"
        case .macros: "text.badge.plus"
        case .aboutSupport: SettingsSymbol.infoFill
        }
    }

    public var sidebarTint: SettingsPaneTint {
        switch self {
        case .general: .gray
        case .typing: .blue
        case .apps: .indigo
        case .macros: .orange
        case .aboutSupport: .green
        }
    }

    /// Command+1 to Command+5 select the panes in sidebar order (PRD-R67 keyboard navigation).
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public init?(shortcutNumber: Int) {
        let panes = Self.allCases
        guard (1...panes.count).contains(shortcutNumber) else { return nil }
        self = panes[panes.index(panes.startIndex, offsetBy: shortcutNumber - 1)]
    }

    /// The pane for a key event pressed with Command only, from its characters ignoring modifiers: one ASCII digit
    /// from 1 to 5.
    public static func forShortcut(characters: String?) -> SettingsPaneKind? {
        guard let characters, characters.count == 1, let digit = characters.first, digit.isASCII,
            let number = digit.wholeNumberValue
        else { return nil }
        return SettingsPaneKind(shortcutNumber: number)
    }

    /// The pane for a key equivalent: Command alone (caps lock and the keypad bit aside) with a digit from 1 to 5.
    /// `modifierFlags` carries the bits NSEvent.ModifierFlags and CGEventFlags share.
    public static func forKeyEquivalent(characters: String?, modifierFlags: UInt64) -> SettingsPaneKind? {
        guard modifierFlags & ShortcutModifier.significant == ShortcutModifier.command else { return nil }
        return forShortcut(characters: characters)
    }
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
                    items: [.englishRestore, .keepAsTyped, .keepVietnamese]),
            ]
        case .apps: []
        case .macros: [SettingsSection(header: nil, items: [.macrosEnabled])]
        case .aboutSupport:
            [
                SettingsSection(
                    header: CatalogText(SupportText.updatesTitle),
                    items: [.updateChannel, .automaticallyCheckForUpdates, .automaticallyInstallUpdates])
            ]
        }
    }
}

/// Window sizes, in points, like System Settings: about 715 x 470 at the least, resizable; the default opens General
/// and Typing without scrolling on a 13-inch display at its default scaling, 1440 x 900 points (PRD-R24 acceptance).
/// The size and position are remembered (PRD-R28).
public enum SettingsWindowLayout {
    public static let minimumWidth = 715.0
    public static let minimumHeight = 470.0
    public static let defaultWidth = 780.0
    public static let defaultHeight = 740.0
    /// Fixed: the sidebar does not collapse or resize, like System Settings.
    public static let sidebarWidth = 190.0
}
