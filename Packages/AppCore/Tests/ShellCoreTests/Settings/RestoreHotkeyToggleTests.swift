// SPDX-License-Identifier: GPL-3.0-or-later
//
// 03-product.md D8, PRD-R18 (decision of the product owner, 13/11/2026): the restore key is Escape by default
// with an on/off switch, the user can record another key, and the explanation states the second-press rule and
// the automatic exclusions (PLT-R353, ENG-R702).

import AppModel
import Foundation
import SettingsStore
import TestSupport
import Testing

@testable import ShellCore

@Suite struct RestoreHotkeyToggleTests {
    static let escape = HotkeyBinding.key(.escape)
    static let f5 = HotkeyBinding.key(KeyCode(rawValue: 0x60))

    @Test func switchIsOnWithAnyBindingAndOffWithNone() {
        #expect(RestoreHotkeyToggle.isOn(UserSettings().resolved().restoreHotkey))
        #expect(RestoreHotkeyToggle.isOn(Self.f5))
        #expect(!RestoreHotkeyToggle.isOn(nil))
    }

    /// Off stores the explicit none (`null`, PRD-R6); on brings back Escape, or keeps a key already bound.
    @Test func switchEditsStoreAnExplicitChoice() {
        var settings = UserSettings()
        RestoreHotkeyToggle.edit(turningOn: false, current: Self.escape).apply(to: &settings)
        #expect(settings.restoreHotkey == .set(nil))
        #expect(settings.resolved().restoreHotkey == nil)
        RestoreHotkeyToggle.edit(turningOn: true, current: nil).apply(to: &settings)
        #expect(settings.restoreHotkey == .set(Self.escape))
        RestoreHotkeyToggle.edit(turningOn: true, current: Self.f5).apply(to: &settings)
        #expect(settings.restoreHotkey == .set(Self.f5))
        #expect(RestoreHotkeyToggle.defaultBinding == Self.escape)
    }

    /// PRD-R18: the explanation names Escape as the default, the second-press rule and the automatic exclusions,
    /// in both languages.
    @Test func explanationStatesTheDefaultTheSecondPressRuleAndTheExclusions() throws {
        let localizers = try Localizers()
        let vi = localizers.vi.string(SettingsText.restoreHotkeyExplanation)
        let en = localizers.en.string(SettingsText.restoreHotkeyExplanation)
        #expect(vi.contains("Mặc định là Escape") && vi.contains("Bấm thêm lần nữa") && vi.contains("tự tắt"))
        #expect(en.contains("default is Escape") && en.contains("again right away") && en.contains("off automatically"))
        #expect(!vi.contains("Gợi ý") && !en.contains("Suggested"))
        // The rejection message in the same pane names the same default.
        let rejectedVi = localizers.vi.string(SettingsText.hotkeyRejectedRestoreModifierTap)
        let rejectedEn = localizers.en.string(SettingsText.hotkeyRejectedRestoreModifierTap)
        #expect(rejectedVi.hasSuffix("Mặc định là Escape.") && !rejectedVi.contains("Gợi ý"))
        #expect(rejectedEn.hasSuffix("The default is Escape.") && !rejectedEn.contains("Suggested"))
        #expect(localizers.vi.string(SettingsText.restoreHotkeySwitch) == "Dùng phím khôi phục")
        #expect(localizers.en.string(SettingsText.restoreHotkeySwitch) == "Use a restore key")
    }
}
