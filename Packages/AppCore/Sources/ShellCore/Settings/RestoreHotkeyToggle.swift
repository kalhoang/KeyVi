// SPDX-License-Identifier: GPL-3.0-or-later
//
// The on/off switch of the restore-last-word hotkey (03-product.md D8, PRD-R18; decision of the product owner,
// 13/11/2026, Q14). There is no separate stored flag: off is the explicit "none" (`restoreHotkey: null` in
// settings.json, PRD-R6), on is a binding. Turning the switch on again gives the default key, Escape.

public import AppModel
internal import SettingsStore

public enum RestoreHotkeyToggle {
    /// The switch shows on whenever a key is bound.
    public static func isOn(_ binding: HotkeyBinding?) -> Bool { binding != nil }

    /// The edit for a change of the switch. Turning it on while a key is already bound keeps that key.
    public static func edit(turningOn on: Bool, current: HotkeyBinding?) -> SettingsEdit {
        guard on else { return .restoreHotkey(nil) }
        return .restoreHotkey(current ?? defaultBinding)
    }

    /// D8: Escape, from the shipped defaults (PRD-R5).
    public static var defaultBinding: HotkeyBinding { DefaultSettings.v1.restoreHotkey ?? .key(.escape) }
}
