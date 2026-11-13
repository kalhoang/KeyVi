// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R11 menu order, PRD-R57 single donation entry, HotkeyDisplay.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct MenuModelTests {
    let app = MenuModel.FrontmostAppMenu(
        bundle: BundleKey(rawValue: "com.example.Chat")!, displayName: "Chat", rule: .alwaysVietnamese)

    func model(status: StatusLine? = nil, frontmost: MenuModel.FrontmostAppMenu? = nil) -> MenuModel {
        MenuModel(
            statusLine: status, mode: .english, toggleHotkeyDisplay: "⌃⇧", method: .vni, frontmostApp: frontmost,
            appName: "Example", updateCheckEnabled: false)
    }

    @Test func fullMenuMatchesPRDR11Order() throws {
        let status = try #require(
            StatusLine.forState(
                .noPermission, holderHintKey: nil, appName: "Example", frontmostApp: nil, tapRecentlyReenabled: false))
        let entries = model(status: status, frontmost: app).entries
        #expect(
            entries == [
                .status(status), .statusAction(status), .separator,
                .mode(.vietnamese, isSelected: false, hotkey: "⌃⇧"), .mode(.english, isSelected: true, hotkey: "⌃⇧"),
                .separator,
                .method(.telex, isSelected: false), .method(.vni, isSelected: true),
                .perApp(app),
                .separator, .macros, .settings,
                .separator, .reportProblem, .checkForUpdates(enabled: false),
                .donate, .quit,
            ])
    }

    @Test func conditionalItemsDisappear() {
        let entries = model().entries
        #expect(!entries.contains { if case .status = $0 { true } else { false } })
        #expect(!entries.contains { if case .perApp = $0 { true } else { false } })
        #expect(entries.first == .mode(.vietnamese, isSelected: false, hotkey: "⌃⇧"))
        #expect(entries.last == .quit)
    }

    @Test func statusLineWithoutActionHasNoActionItem() {
        let line = StatusLine(key: StatusText.builtInVietnamese.rawValue, arguments: ["Example"], action: .none)
        let entries = model(status: line).entries
        #expect(Array(entries.prefix(2)) == [.status(line), .separator])
    }

    @Test func exactlyOneDonationEntryWithoutBadge() {
        // PRD-R57, PRD-R58
        let entries = model(frontmost: app).entries
        #expect(entries.filter { $0 == .donate }.count == 1)
        #expect(MenuEntry.donate.titleKey == .donate)
    }

    @Test func everyEntryHasTitleAndHintKeys() {
        let status = StatusLine(key: "k", arguments: [], action: .reportProblem, actionLabelKey: "a")
        for entry in model(status: status, frontmost: app).entries {
            switch entry {
            case .separator:
                #expect(entry.titleKey == nil && entry.accessibilityHintKey == nil)
            case .status, .statusAction:
                #expect(entry.titleKey == nil)
                #expect(entry.accessibilityHintKey == .statusHint)
            default:
                #expect(entry.titleKey != nil, "\(entry)")
                #expect(entry.accessibilityHintKey != nil, "\(entry)")
            }
        }
        #expect(MenuEntry.settings.commandKeyEquivalent == ",")
        #expect(MenuEntry.quit.commandKeyEquivalent == "q")
        #expect(MenuEntry.macros.commandKeyEquivalent == nil)
    }

    @Test func perAppRulesInSubmenuOrder() {
        #expect(PerAppRule.allCases == [.remember, .alwaysEnglish, .alwaysVietnamese, .ignore])
        #expect(
            PerAppRule.allCases.map(\.menuTitleKey) == [
                .ruleRemember, .ruleAlwaysEnglish, .ruleAlwaysVietnamese, .ruleIgnore,
            ])
    }

    @Test func menuCopyIsVerbatim() throws {
        let bundle = try TemporaryAppBundle(catalogs: [.menu])
        let vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        #expect(vi.format(MenuText.perAppTitle, "Zalo") == "Với Zalo")
        #expect(vi.string(MenuText.perAppReport) == "Báo lỗi với ứng dụng này...")
        #expect(vi.string(MenuText.reportProblem) == "Báo lỗi...")
        #expect(vi.string(MenuText.checkForUpdates) == "Kiểm tra cập nhật...")
        #expect(vi.format(MenuText.donate, "Example") == "Ủng hộ Example...")
        #expect(vi.format(MenuText.quit, "Example") == "Thoát Example")
        #expect(vi.string(MenuText.ruleIgnore) == "Bỏ qua ứng dụng này")
    }
}

@Suite struct HotkeyDisplayTests {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: [.menu])
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
    }

    @Test func modifierTaps() {
        #expect(HotkeyDisplay.string(for: .defaultToggle, localizer: vi) == "⌃⇧")
        #expect(HotkeyDisplay.string(for: .modifierTap(.commandShift), localizer: vi) == "⇧⌘")
        #expect(HotkeyDisplay.string(for: .modifierTap(.optionShift), localizer: vi) == "⌥⇧")
        #expect(HotkeyDisplay.string(for: .modifierTap(.controlOption), localizer: vi) == "⌃⌥")
        #expect(HotkeyDisplay.string(for: .modifierTap(.rightCommand), localizer: vi) == "⌘ phải")
        #expect(HotkeyDisplay.string(for: .modifierTap(.rightOption), localizer: en) == "Right ⌥")
    }

    @Test func combosUseAppleModifierOrder() {
        let combo = HotkeyBinding.keyCombo(modifiers: [.command, .option], keyCode: KeyCode(rawValue: 0x28))
        #expect(HotkeyDisplay.string(for: combo, localizer: vi) == "⌥⌘K")
        let all = HotkeyBinding.keyCombo(modifiers: [.command, .shift, .option, .control, .function], keyCode: .space)
        #expect(HotkeyDisplay.string(for: all, localizer: en) == "fn⌃⌥⇧⌘Space")
        #expect(HotkeyDisplay.string(for: all, localizer: vi) == "fn⌃⌥⇧⌘Phím cách")
    }

    @Test func singleKeysAndUnknownCodes() {
        #expect(HotkeyDisplay.string(for: .key(.escape), localizer: vi) == "⎋")
        #expect(HotkeyDisplay.string(for: .key(KeyCode(rawValue: 0x7A)), localizer: vi) == "F1")
        #expect(HotkeyDisplay.string(for: .key(KeyCode(rawValue: 0x5A)), localizer: vi) == "F20")
        #expect(HotkeyDisplay.string(for: .key(KeyCode(rawValue: 0x12)), localizer: vi) == "1")
        #expect(HotkeyDisplay.string(for: .key(KeyCode(rawValue: 0xA0)), localizer: en) == "Key 160")
        #expect(HotkeyDisplay.string(for: .key(KeyCode(rawValue: 0xA0)), localizer: vi) == "Phím 160")
        for code in [
            KeyCode.returnKey, .tab, .delete, .forwardDelete, .home, .end, .pageUp, .pageDown, .leftArrow,
            .rightArrow, .upArrow, .downArrow, .keypadEnter,
        ] {
            #expect(HotkeyDisplay.string(for: .key(code), localizer: vi).count == 1)
        }
    }
}
