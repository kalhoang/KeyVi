// SPDX-License-Identifier: GPL-3.0-or-later
//
// The keys of the `settings` object of settings.json, one descriptor per `Setting<Value>` of `UserSettings`.
// Decoding, encoding, reset scopes, the diagnostics key list and the import summary all walk this table, so a
// new setting is added in exactly one place (plus `UserSettings` and `DefaultSettings`).

internal import AppModel

/// Which reset scope a setting belongs to (PRD-R26, panes of 03-product.md section 7).
enum SettingGroup: Sendable, Hashable {
    case general, typing, apps, macros, updates
}

/// One `Setting<Value>` key. Closures are type-erased over `Value` so the table is a plain array.
struct SettingField: Sendable {
    let key: String
    let group: SettingGroup
    let isSet: @Sendable (UserSettings) -> Bool
    /// Same value (including set/unset) in both.
    let isEqual: @Sendable (UserSettings, UserSettings) -> Bool
    /// Sets the field from JSON; returns false (field untouched) when the value is invalid for this build.
    let decode: @Sendable (JSONValue, inout UserSettings) -> Bool
    /// JSON for a set value, nil when unset (absent key, PRD-R6).
    let encode: @Sendable (UserSettings) -> JSONValue?
    /// True when `raw` decodes to exactly the current value: the writer then keeps `raw` verbatim, so unknown
    /// keys nested inside a value (for example inside a hotkey object) survive (PLT-R1002).
    let rawMatches: @Sendable (JSONValue, UserSettings) -> Bool
    let unset: @Sendable (inout UserSettings) -> Void

    /// True when this build can read `json` as a value of this setting.
    func decodes(_ json: JSONValue) -> Bool {
        var probe = UserSettings()
        return decode(json, &probe)
    }
}

enum SettingFields {
    static let all: [SettingField] = [
        field("typingMethod", \.typingMethod, .typing),
        field("tonePlacement", \.tonePlacement, .typing),
        field("englishRestore", \.englishRestore, .typing),
        field("telexStandaloneW", \.telexStandaloneW, .typing),
        field("telexBracketKeys", \.telexBracketKeys, .typing),
        // PRD-R18: exactly two configurable hotkeys. A bare key is allowed only for restore (D8, Escape).
        field("restoreHotkey", \.restoreHotkey, .typing) { $0?.isAllowed(for: .restoreLastWord) ?? true },
        field("macrosEnabled", \.macrosEnabled, .macros),
        field("macrosInEnglishMode", \.macrosInEnglishMode, .macros),
        field("toggleHotkey", \.toggleHotkey, .general) { $0.isAllowed(for: .toggleMode) },
        field("rememberPerApp", \.rememberPerApp, .general),
        field("firstSeenAppMode", \.firstSeenAppMode, .apps),
        field("showSwitchIndicator", \.showSwitchIndicator, .general),
        field("soundOnSwitch", \.soundOnSwitch, .general),
        field("clickIconToToggle", \.clickIconToToggle, .general),
        field("interfaceLanguage", \.interfaceLanguage, .general),
        field("automaticallyCheckForUpdates", \.automaticallyCheckForUpdates, .updates),
        field("automaticallyInstallUpdates", \.automaticallyInstallUpdates, .updates),
        field("updateChannel", \.updateChannel, .updates),
        field("layoutBinding", \.layoutBinding, .general),
        field("learnCollisionChoices", \.learnCollisionChoices, .typing),  // D28
        field("lookaheadRevision", \.lookaheadRevision, .typing),  // D29
        field("typoCorrection", \.typoCorrection, .typing),  // D30 (1.1.0)
    ]

    static let keys: Set<String> = Set(all.map(\.key))

    private static func field<Value>(
        _ key: String, _ path: any WritableKeyPath<UserSettings, Setting<Value>> & Sendable, _ group: SettingGroup,
        accept: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) -> SettingField {
        let decodeValue: @Sendable (JSONValue) -> Value? = { json in
            guard let value = JSONSupport.decode(Value.self, from: json), accept(value) else { return nil }
            return value
        }
        return SettingField(
            key: key, group: group,
            isSet: { $0[keyPath: path].isSet },
            isEqual: { $0[keyPath: path] == $1[keyPath: path] },
            decode: { json, settings in
                guard let value = decodeValue(json) else { return false }
                settings[keyPath: path] = .set(value)
                return true
            },
            encode: { settings in
                guard case .set(let value) = settings[keyPath: path] else { return nil }
                return JSONSupport.encode(value)
            },
            rawMatches: { json, settings in
                guard case .set(let current) = settings[keyPath: path], let value = decodeValue(json) else {
                    return false
                }
                return value == current
            },
            unset: { $0[keyPath: path] = .unset })
    }
}

/// Keys of `UserSettings` that are plain collections rather than `Setting<Value>` (reported when non-empty).
enum SettingListKey {
    static let keepAsTyped = "keepAsTyped"
    static let keepVietnamese = "keepVietnamese"
    static let learnedWords = "learnedWords"  // ENG-R862, inside `englishRestoreLists`
    static let neverCorrect = "neverCorrect"  // ENG-R1118, inside `englishRestoreLists` (1.1.0)
    static let optedInRules = "optedInRules"
    static let onboarding = "onboarding"
}
