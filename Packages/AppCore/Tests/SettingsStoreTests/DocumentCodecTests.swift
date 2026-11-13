// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import Testing

@testable import SettingsStore

private func object(_ text: String) throws -> [String: JSONValue] {
    try JSONSupport.parseObject(Data(text.utf8))
}

private func bundle(_ raw: String) -> BundleKey { BundleKey(rawValue: raw)! }

@Suite struct SettingsCodecTests {
    @Test func absentIsUnsetAndNullIsExplicitNonePRDR6() throws {
        let user = SettingsCodec.decode(try object(#"{"settings":{"restoreHotkey":null}}"#))
        #expect(user.restoreHotkey == .set(nil))
        #expect(user.typingMethod == .unset)
        let encoded = SettingsCodec.encode(user, over: [:])
        #expect(encoded["settings"]?["restoreHotkey"] == .null)
        #expect(encoded["settings"]?["typingMethod"] == nil)
    }

    @Test func setToTheDefaultValueStaysSetPRDR6() throws {
        var user = UserSettings()
        user.typingMethod = .set(DefaultSettings.v1.typingMethod)
        let decoded = SettingsCodec.decode(SettingsCodec.encode(user, over: [:]))
        #expect(decoded.typingMethod == .set(.telex))
        #expect(decoded == user)
    }

    @Test func unknownKeysSurviveAtEveryLevelPLTR1002() throws {
        let raw = try object(SchemaFixtures.v1.settings)
        var user = SettingsCodec.decode(raw)
        user.typingMethod = .set(.telex)
        user.keepAsTyped.insert("wifi")
        let encoded = SettingsCodec.encode(user, over: raw)
        #expect(encoded["futureKeyFromNewerBuild"] == .object(["kept": .bool(true)]))
        #expect(encoded["settings"]?["futureSettingFromNewerBuild"] == .string("kept"))
        #expect(encoded["englishRestoreLists"]?["futureList"] == .array([.number(1)]))
        #expect(encoded["onboarding"]?["futureStep"] == .number(3))
        // The hotkey was not changed, so its raw object, including the unknown nested key, is kept verbatim.
        #expect(encoded["settings"]?["toggleHotkey"]?["futureHotkeyField"] == .number(7))
        #expect(encoded["settings"]?["typingMethod"] == .string("telex"))
        #expect(encoded["englishRestoreLists"]?["keepAsTyped"] == .array([.string("tex"), .string("wifi")]))
    }

    @Test func changedValueReplacesTheRawValue() throws {
        let raw = try object(SchemaFixtures.v1.settings)
        var user = SettingsCodec.decode(raw)
        user.toggleHotkey = .set(.defaultToggle)
        user.restoreHotkey = .unset
        let encoded = SettingsCodec.encode(user, over: raw)
        #expect(encoded["settings"]?["toggleHotkey"] == JSONSupport.encode(HotkeyBinding.defaultToggle))
        #expect(encoded["settings"]?["restoreHotkey"] == nil)
    }

    @Test func onlyTwoHotkeysAndTheirRolesPRDR18() throws {
        let hotkeyKeys = SettingFields.all.filter { field in
            var probe = UserSettings()
            return field.decode(JSONSupport.encode(HotkeyBinding.defaultToggle)!, &probe)
        }.map(\.key)
        #expect(Set(hotkeyKeys) == ["toggleHotkey", "restoreHotkey"])
        let bareEscape = #"{"type":"key","keyCode":53}"#
        let user = SettingsCodec.decode(
            try object(#"{"settings":{"toggleHotkey":\#(bareEscape),"restoreHotkey":\#(bareEscape)}}"#))
        #expect(user.toggleHotkey == .unset)
        #expect(user.restoreHotkey == .set(.key(KeyCode(rawValue: 53))))
        let noModifiers = #"{"type":"keyCombo","modifiers":0,"keyCode":49}"#
        #expect(
            SettingsCodec.decode(try object(#"{"settings":{"restoreHotkey":\#(noModifiers)}}"#)).restoreHotkey == .unset
        )
    }

    @Test func invalidKnownValuesReadAsUnsetAndAreListed() throws {
        let raw = try object(#"{"settings":{"typingMethod":"dvorak","englishRestore":"yes","newThing":1},"extra":2}"#)
        let user = SettingsCodec.decode(raw)
        #expect(user == UserSettings())
        #expect(
            SettingsCodec.skippedPaths(in: raw) == [
                "extra", "settings.englishRestore", "settings.newThing", "settings.typingMethod",
            ])
        // PRD-R6, PLT-R1002: a value a newer build wrote (for example a new enum case) stays verbatim while the
        // field is unset here, so a downgrade does not lose the user's choice.
        let encoded = SettingsCodec.encode(user, over: raw)["settings"]
        #expect(encoded?["typingMethod"] == .string("dvorak"))
        #expect(encoded?["englishRestore"] == .string("yes"))
        #expect(encoded?["newThing"] == .number(1))
        var chosen = user
        chosen.typingMethod = .set(.telex)
        #expect(SettingsCodec.encode(chosen, over: raw)["settings"]?["typingMethod"] == .string("telex"))
    }

    @Test func aDecodableValueIsRemovedWhenTheFieldIsUnset() throws {
        let raw = try object(#"{"settings":{"typingMethod":"vni"}}"#)
        #expect(SettingsCodec.encode(UserSettings(), over: raw)["settings"]?["typingMethod"] == nil)
    }

    @Test func listsAreLowercasedAndRuleIDsValidated() throws {
        let raw = try object(
            #"{"englishRestoreLists":{"keepAsTyped":["TeX",""," ",3]},"optedInRules":["ok.rule","bad rule",1]}"#)
        let user = SettingsCodec.decode(raw)
        #expect(user.keepAsTyped == ["tex", " "])
        #expect(user.optedInRules == [RuleID(rawValue: "ok.rule")!])
    }

    /// A `Setting` added to `UserSettings` without a row in `SettingFields` would never be saved.
    @Test func everySettingPropertyHasAFieldWithTheSameName() {
        let settingProperties = Mirror(reflecting: UserSettings()).children.compactMap { child -> String? in
            String(describing: type(of: child.value)).hasPrefix("Setting<") ? child.label : nil
        }
        #expect(settingProperties == SettingFields.all.map(\.key))
    }

    @Test func explicitlySetKeysNamesOnly() {
        var user = UserSettings()
        #expect(user.explicitlySetKeys.isEmpty)
        user.tonePlacement = .set(.modern)
        user.restoreHotkey = .set(nil)
        user.keepVietnamese = ["mas"]
        #expect(user.explicitlySetKeys == ["tonePlacement", "restoreHotkey", "keepVietnamese"])
    }

    @Test func defaultsMatchTheProductTablePRDR5() {
        let defaults = DefaultSettings.v1
        #expect(defaults.typingMethod == .telex)
        #expect(defaults.tonePlacement == .traditional)
        #expect(defaults.englishRestore && defaults.telexStandaloneW && !defaults.telexBracketKeys)
        #expect(defaults.restoreHotkey == nil)
        #expect(defaults.macrosEnabled && !defaults.macrosInEnglishMode)
        #expect(defaults.toggleHotkey == .modifierTap(.controlShift))
        #expect(defaults.rememberPerApp && defaults.firstSeenAppMode == .inherit)
        #expect(defaults.showSwitchIndicator && !defaults.soundOnSwitch && !defaults.clickIconToToggle)
        #expect(defaults.interfaceLanguage == .vietnamese)
        #expect(defaults.automaticallyCheckForUpdates && defaults.automaticallyInstallUpdates)
        #expect(defaults.updateChannel == .stable)
        #expect(UserSettings().resolved() == defaults)
    }

    /// PRD-R6: a changed default reaches unset keys only.
    @Test func changingADefaultAffectsOnlyUnsetKeys() {
        var user = UserSettings()
        user.tonePlacement = .set(.traditional)
        var newDefaults = DefaultSettings.v1
        newDefaults.tonePlacement = .modern
        newDefaults.typingMethod = .vni
        let effective = user.resolved(over: newDefaults)
        #expect(effective.tonePlacement == .traditional)
        #expect(effective.typingMethod == .vni)
    }
}

@Suite struct AppModesCodecTests {
    @Test func unknownKeysInEntriesSurviveAndOrderIsKept() throws {
        let raw = try object(SchemaFixtures.v1.appModes)
        var document = AppModesCodec.decode(raw)
        #expect(document.globalMode == .english)
        #expect(document.apps.map(\.bundle.rawValue).first == "com.example.Terminal")
        document.apps[0].mode = .vietnamese
        let encoded = AppModesCodec.encode(document, over: raw)
        #expect(encoded["futureTopLevel"] == .number(1))
        #expect(arrayItems(encoded["apps"]).first?["futureEntryKey"] == .string("x"))
        #expect(arrayItems(encoded["apps"]).first?["mode"] == .string("vi"))
        #expect(arrayItems(encoded["apps"])[1]["mode"] == nil)
        #expect(AppModesCodec.decode(encoded) == document)
    }

    @Test func invalidEntriesAreDroppedAndListed() throws {
        let raw = try object(
            #"""
            {"globalMode":"xx","apps":[{"bundle":"bad key!","mode":"en"},{"bundle":"a.b"},{"bundle":"a.b","mode":"en"},
             {"bundle":"c.d","mode":"vi"},{"bundle":"c.d","mode":"en"},7]}
            """#)
        let document = AppModesCodec.decode(raw)
        #expect(document.globalMode == .vietnamese)
        #expect(
            document.apps == [
                AppModeEntry(bundle: bundle("a.b"), mode: .english),
                AppModeEntry(bundle: bundle("c.d"), mode: .vietnamese),
            ])
        #expect(AppModesCodec.skippedPaths(in: raw) == ["globalMode", "apps[0]", "apps[1]", "apps[5]"])
    }

    @Test func evictsLeastRecentlyUsedMemoryButNeverRulesPLTR392() {
        var apps = (0..<1_005).map { AppModeEntry(bundle: bundle("app.n\($0)"), mode: .english) }
        apps.append(AppModeEntry(bundle: bundle("ruled.app"), rule: .ignore))
        apps.append(AppModeEntry(bundle: bundle("remember.app"), rule: .remember))
        let normalized = AppModesDocument(apps: apps).normalized()
        #expect(normalized.apps.filter { !$0.hasExplicitRule }.count == AppModesDocument.rememberedCapacity)
        #expect(normalized.apps.last?.bundle == bundle("ruled.app"))
        #expect(normalized.apps.contains { $0.bundle == bundle("app.n999") })
        #expect(!normalized.apps.contains { $0.bundle == bundle("app.n1000") })
    }

    @Test func ruleEditingAndMemoryRecording() {
        let start = AppModesDocument(
            globalMode: .vietnamese,
            apps: [
                AppModeEntry(bundle: bundle("a.a"), mode: .english), AppModeEntry(bundle: bundle("b.b"), rule: .ignore),
            ])
        let ruled = start.settingRule(.alwaysEnglish, for: bundle("c.c"))
        #expect(ruled.apps.first == AppModeEntry(bundle: bundle("c.c"), rule: .alwaysEnglish))
        #expect(ruled.settingRule(nil, for: bundle("c.c")) == start)
        #expect(start.settingRule(.remember, for: bundle("b.b")).apps.map(\.bundle) == [bundle("a.a")])
        #expect(
            start.settingRule(.ignore, for: bundle("a.a")).apps[0]
                == AppModeEntry(bundle: bundle("a.a"), rule: .ignore, mode: .english))
        // A stale copy from the ax thread that lacks b.b's rule and carries a bogus rule for a.a.
        let stale = AppModesDocument(
            globalMode: .english,
            apps: [
                AppModeEntry(bundle: bundle("d.d"), mode: .vietnamese),
                AppModeEntry(bundle: bundle("a.a"), rule: .alwaysVietnamese, mode: .english),
            ])
        let recorded = start.recordingMemory(from: stale)
        #expect(recorded.globalMode == .english)
        #expect(
            recorded.apps == [
                AppModeEntry(bundle: bundle("d.d"), mode: .vietnamese),
                AppModeEntry(bundle: bundle("a.a"), mode: .english),
                AppModeEntry(bundle: bundle("b.b"), rule: .ignore),
            ])
    }
}

@Suite struct RuleOverridesAndMacrosCodecTests {
    @Test func overridesKeepRawRuleAndEntryKeysPLTR541() throws {
        let raw = try object(SchemaFixtures.v1.ruleOverrides)
        let overrides = RuleOverridesCodec.decode(raw)
        #expect(overrides.count == 1)
        #expect(overrides[0].createdAt == StorageTimestamp.date(iso: "2026-11-13T09:00:00Z"))
        #expect(overrides[0].rule["strategy"] == .string("paste"))
        let encoded = RuleOverridesCodec.encode(overrides, over: raw)
        #expect(arrayItems(encoded["overrides"]).first?["futureOverrideKey"] == .bool(true))
        #expect(RuleOverridesCodec.decode(encoded) == overrides)
    }

    @Test func invalidOverridesAreDropped() throws {
        let raw = try object(
            #"""
            {"overrides":[{"createdAt":"bad","rule":{"id":"user.a"}},{"createdAt":"2026-11-13T09:00:00Z","rule":{"id":"shipped.a"}},
             {"createdAt":"2026-11-13T09:00:00Z","rule":{"id":"user.a"}},{"createdAt":"2026-11-13T10:00:00Z","rule":{"id":"user.a"}}]}
            """#)
        #expect(RuleOverridesCodec.decode(raw).count == 1)
        #expect(RuleOverridesCodec.skippedPaths(in: raw) == ["overrides[0]", "overrides[1]"])
    }

    @Test func macrosKeepEntryKeysAndDefaultFlags() throws {
        let raw = try object(SchemaFixtures.v1.macros)
        let macros = MacrosCodec.decode(raw)
        #expect(macros.map(\.trigger) == ["vn", "@@"])
        #expect(macros[1].adaptCase == false && macros[1].enabled == false)
        let encoded = MacrosCodec.encode(macros, over: raw)
        #expect(arrayItems(encoded["macros"]).first?["futureMacroKey"] == .string("x"))
        #expect(MacrosCodec.decode(encoded) == macros)
        let loose = try object(
            #"{"macros":[{"trigger":"a1","expansion":"b"},{"trigger":"x"},{"id":"1","trigger":"c1","expansion":"d"}]}"#)
        let decoded = MacrosCodec.decode(loose)
        #expect(decoded.map(\.trigger) == ["a1", "c1"])
        #expect(decoded.allSatisfy { $0.adaptCase && $0.enabled })
        #expect(MacrosCodec.skippedPaths(in: loose) == ["macros[1]"])
    }

    @Test func duplicateMacroIDsGetFreshOnes() throws {
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let raw = try object(
            #"{"macros":[{"id":"\#(id)","trigger":"a1","expansion":"b"},{"id":"\#(id)","trigger":"c1","expansion":"d"}]}"#
        )
        let macros = MacrosCodec.decode(raw)
        #expect(macros[0].id.uuidString == id)
        #expect(macros[1].id.uuidString != id)
    }
}
