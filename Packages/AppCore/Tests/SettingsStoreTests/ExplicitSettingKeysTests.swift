// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R6, PLT-R901: the names of explicitly set settings for the content-free diagnostics report. They are the
// JSON keys of settings.json, the same strings ShellCore's `ExplicitSettingKeys.names` uses (W1-G request), so
// the report can switch to `UserSettings.explicitlySetKeys` without changing its output for settings.

import AppModel
import Foundation
import Testing

@testable import SettingsStore

/// The setting names, in `UserSettings` declaration order. D19 to D21 use the Swift property names, which are
/// also their JSON keys.
private let settingNames = [
    "typingMethod", "tonePlacement", "englishRestore", "telexStandaloneW", "telexBracketKeys", "restoreHotkey",
    "macrosEnabled", "macrosInEnglishMode", "toggleHotkey", "rememberPerApp", "firstSeenAppMode",
    "showSwitchIndicator", "soundOnSwitch", "clickIconToToggle", "interfaceLanguage", "automaticallyCheckForUpdates",
    "automaticallyInstallUpdates", "updateChannel", "layoutBinding",
]

/// The user lists, reported by name when non-empty.
private let listNames = ["keepAsTyped", "keepVietnamese", "optedInRules"]

/// Every setting explicitly set, most of them to their default value (set-to-default still counts, PRD-R6).
private func everythingSet() -> UserSettings {
    var user = UserSettings()
    let defaults = DefaultSettings.v1
    user.typingMethod = .set(.vni)
    user.tonePlacement = .set(defaults.tonePlacement)
    user.englishRestore = .set(false)
    user.telexStandaloneW = .set(defaults.telexStandaloneW)
    user.telexBracketKeys = .set(true)
    user.restoreHotkey = .set(nil)
    user.macrosEnabled = .set(defaults.macrosEnabled)
    user.macrosInEnglishMode = .set(true)
    user.toggleHotkey = .set(defaults.toggleHotkey)
    user.rememberPerApp = .set(false)
    user.firstSeenAppMode = .set(.en)
    user.showSwitchIndicator = .set(false)
    user.soundOnSwitch = .set(true)
    user.clickIconToToggle = .set(true)
    user.interfaceLanguage = .set(.english)
    user.automaticallyCheckForUpdates = .set(false)
    user.automaticallyInstallUpdates = .set(false)
    user.updateChannel = .set(.beta)
    user.layoutBinding = .set(LayoutModeBinding(enabled: true))
    return user
}

@Suite struct ExplicitSettingKeysTests {
    @Test func everySettingIsReportedByItsDiagnosticsNamePRDR6() {
        var user = everythingSet()
        #expect(user.explicitlySetKeys == settingNames)
        user.keepAsTyped = ["mas"]
        user.keepVietnamese = ["tieng"]
        user.optedInRules = [RuleID(rawValue: "chat.paste")!]
        #expect(user.explicitlySetKeys == settingNames + listNames)
    }

    /// Each setting on its own reports exactly its own name: the table has one row per setting.
    @Test func eachSettingAloneReportsOnlyItsName() {
        let full = everythingSet()
        for field in SettingFields.all {
            var user = UserSettings()
            #expect(field.decode(field.encode(full)!, &user))
            #expect(user.explicitlySetKeys == [field.key])
        }
        #expect(SettingFields.all.map(\.key) == settingNames)
    }

    /// The names are the keys written into the `settings` object of settings.json.
    @Test func namesAreTheSettingsJSONKeys() {
        let encoded = SettingsCodec.encode(everythingSet(), over: [:])
        let keys = encoded["settings"]?.objectValue.map { Set($0.keys) }
        #expect(keys == Set(settingNames))
    }

    /// Names only, never values (PLT-R901): list contents and values do not appear.
    @Test func noValuesAreReportedPLTR901() {
        var user = everythingSet()
        user.keepVietnamese = ["canary-4711"]
        #expect(!user.explicitlySetKeys.joined(separator: ",").contains("4711"))
        #expect(!user.explicitlySetKeys.joined(separator: ",").contains("beta"))
        #expect(UserSettings().explicitlySetKeys.isEmpty)
    }
}
