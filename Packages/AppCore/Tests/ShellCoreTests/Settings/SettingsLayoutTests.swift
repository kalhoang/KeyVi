// SPDX-License-Identifier: GPL-3.0-or-later
//
// The System Settings style layout of the Settings window (Pa, 2026-11-14, feedback item 6; PRD-R24, PRD-R25,
// PRD-R67): the sidebar's symbols, tiles and keyboard shortcuts, the grouped sections of each pane and the window's
// sizes.

import AppKit
import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct SettingsLayoutTests {
    @Test func sidebarListsTheSevenPanesWithDistinctSymbolsAndTiles() {
        // PRD-R24 order; every row has its own symbol and tile colour, and the pane name next to it (PRD-R67: the
        // colour is decoration, never the only cue).
        let panes = SettingsPaneKind.allCases
        // Pa, 15/11/2026: About & Support became About, Support and Licences.
        #expect(panes == [.general, .typing, .apps, .macros, .about, .support, .licences])
        #expect(Set(panes.map(\.sidebarSymbol)).count == panes.count)
        #expect(Set(panes.map(\.sidebarTint)).count == panes.count)
        #expect(panes.allSatisfy { !$0.sidebarSymbol.isEmpty })
        #expect(SettingsPaneKind.general.sidebarSymbol == "gearshape.fill")
        #expect(SettingsPaneKind.typing.sidebarSymbol == "keyboard")
    }

    @Test func commandOneToSevenSelectThePanesInSidebarOrder() {
        #expect(SettingsPaneKind.allCases.map(\.shortcutNumber) == [1, 2, 3, 4, 5, 6, 7])
        for pane in SettingsPaneKind.allCases {
            #expect(SettingsPaneKind(shortcutNumber: pane.shortcutNumber) == pane)
            #expect(SettingsPaneKind.forShortcut(characters: String(pane.shortcutNumber)) == pane)
        }
        #expect(SettingsPaneKind(shortcutNumber: 0) == nil)
        #expect(SettingsPaneKind(shortcutNumber: 8) == nil)
        for other in [nil, "", "8", "9", "0", "a", "12", "１"] as [String?] {
            #expect(SettingsPaneKind.forShortcut(characters: other) == nil, "\(other ?? "nil")")
        }
    }

    @Test func onlyCommandWithADigitIsAPaneShortcut() {
        // Bits of NSEvent.ModifierFlags (shared with CGEventFlags): caps lock 16, shift 17, control 18, option 19,
        // command 20, numeric pad 21, function 23. Caps lock and the keypad do not matter; any other modifier does.
        let command: UInt64 = 1 << 20
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "2", modifierFlags: command) == .typing)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "5", modifierFlags: command | 1 << 16) == .about)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "7", modifierFlags: command) == .licences)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: command | 1 << 21) == .general)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "3", modifierFlags: command | 0x0100) == .apps)
        for other: UInt64 in [1 << 17, 1 << 18, 1 << 19, 1 << 23] {
            #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: command | other) == nil)
        }
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "1", modifierFlags: 0) == nil)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "w", modifierFlags: command) == nil)
    }

    @Test func commandDigitsWorkOnLayoutsWithoutDigitsOnTheNumberRow() {
        // French AZERTY gives "&" for the 1 key: like other Mac apps, the key code of the number row (kVK_ANSI_1 to
        // kVK_ANSI_7: 18, 19, 20, 21, 23, 22, 26) selects the pane when the characters are not a digit.
        let command: UInt64 = 1 << 20
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "&", keyCode: 18, modifierFlags: command) == .general)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "(", keyCode: 23, modifierFlags: command) == .about)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "§", keyCode: 22, modifierFlags: command) == .support)
        #expect(
            SettingsPaneKind.forKeyEquivalent(characters: "\u{E8}", keyCode: 26, modifierFlags: command) == .licences)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "\u{E9}", keyCode: 19, modifierFlags: command) == .typing)
        // The characters win when they are a digit; other keys and other modifiers still do nothing.
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "4", keyCode: 18, modifierFlags: command) == .macros)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "&", keyCode: 28, modifierFlags: command) == nil)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "a", keyCode: 0, modifierFlags: command) == nil)
        #expect(
            SettingsPaneKind.forKeyEquivalent(characters: "&", keyCode: 18, modifierFlags: command | 1 << 17) == nil)
        #expect(SettingsPaneKind.forKeyEquivalent(characters: "&", keyCode: 18, modifierFlags: 0) == nil)
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
                [.typingMethod, .tonePlacement],
                [.englishRestore, .keepAsTyped, .keepVietnamese, .learnCollisionChoices],
            ])
        #expect(SettingsCatalog.sections(in: .about).first?.header == CatalogText(SupportText.updatesTitle))
        #expect(SettingsCatalog.sections(in: .support).isEmpty && SettingsCatalog.sections(in: .licences).isEmpty)
        // ENG-R860: the two user lists share one row, side by side; every other setting has a row of its own.
        #expect(
            SettingsCatalog.sections(in: .typing).map(\.rows) == [
                [[.typingMethod], [.tonePlacement]],
                [[.englishRestore], [.keepAsTyped, .keepVietnamese], [.learnCollisionChoices]],
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
        // About 715 x 470 at the least like System Settings, resizable. The content runs under the transparent
        // title bar, so these are the whole window's sizes: the default fits a 13-inch display at its default
        // scaling (1440 x 900 points, minus the menu bar and the Dock), and under its 52 pt title bar row General
        // and Typing need no scrolling (PRD-R24 acceptance; the snapshot tool shows both panes).
        #expect(SettingsWindowLayout.minimumWidth == 715 && SettingsWindowLayout.minimumHeight == 470)
        #expect(SettingsWindowLayout.defaultWidth >= SettingsWindowLayout.minimumWidth)
        #expect(SettingsWindowLayout.defaultHeight >= SettingsWindowLayout.minimumHeight)
        #expect(SettingsWindowLayout.defaultWidth <= 1_440 && SettingsWindowLayout.defaultHeight <= 900 - 25 - 80)
        #expect(SettingsWindowLayout.defaultHeight - 52 >= 714, "room for the Typing pane under the title bar row")
        #expect(SettingsWindowLayout.sidebarWidth >= 160 && SettingsWindowLayout.sidebarWidth <= 220)
        #expect(SettingsWindowLayout.minimumWidth - SettingsWindowLayout.sidebarWidth >= 500, "detail column")
        #expect(SettingsWindowLayout.minimumListWidth == 715 - 190 - 1 - 2 * SettingsWindowLayout.listPaneInset)
    }

    @Test func appsTableFixedColumnsFitTheirLongestValueAndHeader() throws {
        // PRD-R34, PRD-R35: the rule, remembered and status columns are as wide as their longest value in the
        // interface language (plus the pop-up chevron or the status symbol) or their header, so none truncates.
        let l = try Localizers()
        let measure: (String, AppsTableLayout.TextStyle) -> Double = { text, style in
            Double(text.count) * (style == .body ? 2 : 1)
        }
        let en = AppsTableLayout.fixedColumns(localizer: l.en, measure: measure)
        // "Always Vietnamese" (17, small), "Works with notes" (16, body); the header "Remembered" (10, small, plus
        // the header cell's padding) is wider than "Vietnamese" (10, body).
        #expect(en.rule == 17 + AppsTableLayout.ruleAccessoryWidth)
        #expect(en.remembered == 10 + AppsTableLayout.headerPadding)
        #expect(en.status == 32 + AppsTableLayout.statusAccessoryWidth)
        // A header wider than every value sets the width; widths are whole points.
        let wideHeaders = AppsTableLayout.fixedColumns(localizer: l.en) { text, _ in
            text == l.en.string(AppsText.columnRemembered) ? 300.2 : 10
        }
        #expect(wideHeaders.remembered == (300.2 + AppsTableLayout.headerPadding).rounded(.up))
        #expect(wideHeaders.rule == 10 + AppsTableLayout.ruleAccessoryWidth)
    }

    @MainActor @Test func appsTableGivesTheRestOfTheWidthToAppNames() throws {
        // Pa's feedback item 6 (the Settings window looked bad): at the window's minimum width the app name column,
        // the one a user reads first, takes all the room the other columns do not need. Measured with the system
        // font the table uses, a name like "Google Chrome" with its icon fits whole in Vietnamese at the minimum
        // width and in English at the default width (the English rule and status values are longer).
        let l = try Localizers()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let measure: (String, AppsTableLayout.TextStyle) -> Double = { text, style in
            Double((text as NSString).size(withAttributes: [.font: style == .body ? body : small]).width)
        }
        let minimum = SettingsWindowLayout.minimumListWidth
        let iconAndGap = 24.0
        let vi = AppsTableLayout.fixedColumns(localizer: l.vi, measure: measure)
        let chrome = measure("Google Chrome", .body) + iconAndGap
        #expect(AppsTableLayout.appColumnWidth(listWidth: minimum, fixed: vi) >= chrome + 8, "room to spare in vi")
        let en = AppsTableLayout.fixedColumns(localizer: l.en, measure: measure)
        #expect(AppsTableLayout.appColumnWidth(listWidth: minimum, fixed: en) >= 100)
        let atDefault = minimum + SettingsWindowLayout.defaultWidth - SettingsWindowLayout.minimumWidth
        #expect(AppsTableLayout.appColumnWidth(listWidth: atDefault, fixed: en) >= chrome + 20)
        for localizer in [l.vi, l.en] {
            let fixed = AppsTableLayout.fixedColumns(localizer: localizer, measure: measure)
            let app = AppsTableLayout.appColumnWidth(listWidth: minimum, fixed: fixed)
            // No horizontal scrolling: the four columns fit the list at the minimum width.
            #expect(app >= AppsTableLayout.appColumnMinimum)
            #expect(app + fixed.rule + fixed.remembered + fixed.status + AppsTableLayout.tableChrome <= minimum + 0.5)
            // A wider window gives every extra point to the names.
            #expect(AppsTableLayout.appColumnWidth(listWidth: minimum + 65, fixed: fixed) == app + 65)
        }
        #expect(AppsTableLayout.appColumnWidth(listWidth: 100, fixed: vi) == AppsTableLayout.appColumnMinimum)
    }
}
