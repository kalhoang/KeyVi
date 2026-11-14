// SPDX-License-Identifier: GPL-3.0-or-later
//
// The System Settings style layout of the Settings window (Pa, 2026-11-14, feedback item 6; PRD-R24, PRD-R25,
// PRD-R67): the sidebar's symbols, tiles and keyboard shortcuts, the grouped sections of each pane and the window's
// sizes.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct SettingsLayoutTests {
    @Test func sidebarListsTheFivePanesWithDistinctSymbolsAndTiles() {
        // PRD-R24 order; every row has its own symbol and tile colour, and the pane name next to it (PRD-R67: the
        // colour is decoration, never the only cue).
        let panes = SettingsPaneKind.allCases
        #expect(panes == [.general, .typing, .apps, .macros, .aboutSupport])
        #expect(Set(panes.map(\.sidebarSymbol)).count == panes.count)
        #expect(Set(panes.map(\.sidebarTint)).count == panes.count)
        #expect(panes.allSatisfy { !$0.sidebarSymbol.isEmpty })
        #expect(SettingsPaneKind.general.sidebarSymbol == "gearshape.fill")
        #expect(SettingsPaneKind.typing.sidebarSymbol == "keyboard")
    }

    @Test func commandOneToFiveSelectThePanesInSidebarOrder() {
        #expect(SettingsPaneKind.allCases.map(\.shortcutNumber) == [1, 2, 3, 4, 5])
        for pane in SettingsPaneKind.allCases {
            #expect(SettingsPaneKind(shortcutNumber: pane.shortcutNumber) == pane)
            #expect(SettingsPaneKind.forShortcut(characters: String(pane.shortcutNumber)) == pane)
        }
        #expect(SettingsPaneKind(shortcutNumber: 0) == nil)
        #expect(SettingsPaneKind(shortcutNumber: 6) == nil)
        for other in [nil, "", "6", "0", "a", "12", "１"] as [String?] {
            #expect(SettingsPaneKind.forShortcut(characters: other) == nil, "\(other ?? "nil")")
        }
    }

    @Test func onlyCommandWithADigitIsAPaneShortcut() {
        // Bits of NSEvent.ModifierFlags (shared with CGEventFlags): caps lock 16, shift 17, control 18, option 19,
        // command 20, numeric pad 21, function 23. Caps lock and the keypad do not matter; any other modifier does.
        let command: UInt64 = 1 << 20
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "2", modifierFlags: command) == .typing)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "5", modifierFlags: command | 1 << 16) == .aboutSupport)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: command | 1 << 21) == .general)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "3", modifierFlags: command | 0x0100) == .apps)
        for other: UInt64 in [1 << 17, 1 << 18, 1 << 19, 1 << 23] {
            #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: command | other) == nil)
        }
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: 0) == nil)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "w", modifierFlags: command) == nil)
    }

    @Test func sectionsHoldEveryVisibleSettingOnceInSpecOrder() {
        // PRD-R24: the grouped sections split a pane's settings without dropping, repeating or reordering one;
        // Advanced settings stay in the disclosure.
        for pane in SettingsPaneKind.allCases {
            let sections = SettingsCatalog.sections(in: pane)
            #expect(sections.flatMap(\.items) == SettingsCatalog.items(in: pane, advanced: false), "\(pane)")
            #expect(sections.allSatisfy { !$0.items.isEmpty }, "\(pane) has an empty section")
            #expect(sections.allSatisfy { $0.rows.flatMap { $0 } == $0.items }, "\(pane) rows drop or add items")
            let headers = sections.compactMap(\.header)
            #expect(Set(headers).count == headers.count, "\(pane) repeats a header")
        }
        #expect(SettingsCatalog.sections(in: .apps).isEmpty)
        #expect(
            SettingsCatalog.sections(in: .general).map(\.items) == [
                [.openAtLogin], [.toggleHotkey, .rememberPerApp, .switchIndicator], [.interfaceLanguage],
            ])
        #expect(
            SettingsCatalog.sections(in: .typing).map(\.items) == [
                [.typingMethod, .tonePlacement], [.englishRestore, .keepAsTyped, .keepVietnamese],
            ])
        #expect(SettingsCatalog.sections(in: .aboutSupport).first?.header == CatalogText(SupportText.updatesTitle))
        // ENG-R860: the two user lists share one row, side by side; every other setting has a row of its own.
        #expect(
            SettingsCatalog.sections(in: .typing).map(\.rows) == [
                [[.typingMethod], [.tonePlacement]], [[.englishRestore], [.keepAsTyped, .keepVietnamese]],
            ])
        #expect(SettingsSection(header: nil, items: [.keepVietnamese, .keepAsTyped]).rows.count == 2, "only in order")
    }

    @Test func sectionHeadersAndLayoutCopyExistInViAndEn() throws {
        // PRD-R62: standard Vietnamese and a faithful English translation for every new header.
        let l = try Localizers()
        var texts = SettingsPaneKind.allCases.flatMap { SettingsCatalog.sections(in: $0).compactMap(\.header) }
        texts += [CatalogText(SettingsText.resetPaneExplanation), CatalogText(SupportText.settingsExplanation)]
        for text in texts {
            let vi = l.vi.string(text)
            let en = l.en.string(text)
            #expect(vi != text.key && en != text.key, "\(text.key) missing")
            #expect(vi != en || vi == "Beta", "\(text.key) is not translated")
        }
        #expect(l.vi.string(SettingsText.sectionSwitching) == "Chuyển Việt/Anh")
        #expect(l.en.string(SettingsText.sectionEnglish) == "English words")
        // The sidebar's VoiceOver hint names the keys that move between panes (PRD-R66, PRD-R67).
        #expect(l.vi.accessibilityHint(SettingsControl.panePicker).contains("Command + 1"))
        #expect(l.en.accessibilityHint(SettingsControl.panePicker).contains("Command+1"))
    }

    @Test func windowSizesFollowSystemSettings() {
        // About 715 x 470 at the least like System Settings, resizable; the default window (title bar included)
        // fits a 13-inch display at its default scaling (1440 x 900 points, minus the menu bar and the Dock), and
        // General and Typing need no scrolling there (PRD-R24 acceptance; the snapshot tool shows both panes).
        #expect(SettingsWindowLayout.minimumWidth == 715 && SettingsWindowLayout.minimumHeight == 470)
        #expect(SettingsWindowLayout.defaultWidth >= SettingsWindowLayout.minimumWidth)
        #expect(SettingsWindowLayout.defaultHeight >= SettingsWindowLayout.minimumHeight)
        #expect(SettingsWindowLayout.defaultWidth <= 1_440 && SettingsWindowLayout.defaultHeight + 28 <= 900 - 25 - 80)
        #expect(SettingsWindowLayout.sidebarWidth >= 160 && SettingsWindowLayout.sidebarWidth <= 220)
        #expect(SettingsWindowLayout.minimumWidth - SettingsWindowLayout.sidebarWidth >= 500, "detail column")
    }
}
