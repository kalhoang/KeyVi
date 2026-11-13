// SPDX-License-Identifier: GPL-3.0-or-later
//
// 03-product.md D8, PRD-R18 (decision of the product owner, 13/11/2026, Q14): Escape is the default restore key.
// Only explicit choices are persisted (PLT-R1001, PLT-R1004), so the migration needs no rewrite: a settings file
// without `restoreHotkey` resolves to Escape, an explicit `null` ("none", the off switch) stays none, and a
// recorded key stays that key.

import AppModel
import Foundation
import Testing

@testable import SettingsStore

@Suite struct RestoreHotkeyDefaultTests {
    static let escape = HotkeyBinding.key(.escape)

    private func resolved(_ json: String) throws -> HotkeyBinding? {
        SettingsCodec.decode(try JSONSupport.parseObject(Data(json.utf8))).resolved().restoreHotkey
    }

    @Test func defaultIsEscape_D8() {
        #expect(DefaultSettings.v1.restoreHotkey == Self.escape)
        #expect(UserSettings().resolved().restoreHotkey == Self.escape)
    }

    @Test func usersWhoNeverSetTheKeyGetEscape() throws {
        #expect(try resolved(#"{"settings":{}}"#) == Self.escape)
        #expect(try resolved(#"{"settings":{"typingMethod":"vni"}}"#) == Self.escape)
        #expect(try resolved(#"{}"#) == Self.escape)
    }

    @Test func explicitNoneStaysNone() throws {
        #expect(try resolved(#"{"settings":{"restoreHotkey":null}}"#) == nil)
        var user = UserSettings()
        user.restoreHotkey = .set(nil)
        #expect(user.resolved().restoreHotkey == nil)
        #expect(user.explicitlySetKeys.contains("restoreHotkey"))
    }

    /// Choosing Escape explicitly is stored, so a later change of the default would not move this user.
    @Test func explicitKeysStay() {
        var user = UserSettings()
        user.restoreHotkey = .set(.key(KeyCode(rawValue: 0x60)))
        #expect(user.resolved().restoreHotkey == .key(KeyCode(rawValue: 0x60)))
        user.restoreHotkey = .set(Self.escape)
        #expect(user.resolved().restoreHotkey == Self.escape)
        #expect(SettingsCodec.encode(user, over: [:])["settings"]?["restoreHotkey"] != nil)
    }
}
