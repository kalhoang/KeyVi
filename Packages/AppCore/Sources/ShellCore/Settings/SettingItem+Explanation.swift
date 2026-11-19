// SPDX-License-Identifier: GPL-3.0-or-later
//
// The explanation a setting's row shows (PRD-R25) when it depends on other settings: copy that names the restore key
// of D8 the way PRD-R78 does (D30 and the never-correct list, PRD-R80 and PRD-R81), and D30's dependency on D4,
// which disables the row and ends its explanation with a suffix (PRD-R80).

public import AppModel
public import SettingsStore

/// The three wordings of a text that names the restore key of D8 (PRD-R78): Escape, D8's default, keeps the draft's
/// wording; another key is named in words; with D8 off the text says the key is off. The first argument of every
/// variant is the app name; the `otherKey` variant takes the key in words as its second.
public struct RestoreKeyWording: Sendable, Hashable {
    public var escape: SettingsText
    public var otherKey: SettingsText
    public var noKey: SettingsText

    public init(escape: SettingsText, otherKey: SettingsText, noKey: SettingsText) {
        self.escape = escape
        self.otherKey = otherKey
        self.noKey = noKey
    }

    /// The variant for `restoreHotkey` (nil: D8 is off).
    public func key(for restoreHotkey: HotkeyBinding?) -> SettingsText {
        switch restoreHotkey {
        case nil: noKey
        case .key(.escape)?: escape
        case .some: otherKey
        }
    }

    public func text(appName: String, restoreHotkey: HotkeyBinding?, _ localizer: Localizer) -> String {
        guard let binding = restoreHotkey, binding != .key(.escape) else {
            return localizer.format(key(for: restoreHotkey), appName)
        }
        return localizer.format(otherKey, appName, ShortcutWords.string(for: binding, localizer: localizer))
    }
}

extension SettingItem {
    /// The setting this one needs on to have any effect: D30 follows D4, since the host passes D30 to the engine
    /// ANDed with D4 (PRD-R80, ENG-R1119). nil for every other setting.
    public var dependsOn: SettingItem? { self == .typoCorrection ? .englishRestore : nil }

    /// False while the setting this one depends on is off: the row is shown disabled (PRD-R80).
    public func isEnabled(in settings: EffectiveSettings) -> Bool {
        dependsOn == .englishRestore ? settings.englishRestore : true
    }

    /// The sentence that ends the explanation while the row is disabled (PRD-R80).
    public var disabledSuffix: CatalogText? {
        self == .typoCorrection ? CatalogText(SettingsText.typoCorrectionDisabledSuffix) : nil
    }

    /// The wordings of an explanation that names the restore key: D30 and the never-correct list (PRD-R80, PRD-R81).
    public var restoreKeyWording: RestoreKeyWording? {
        switch self {
        case .typoCorrection:
            RestoreKeyWording(
                escape: .typoCorrectionExplanation, otherKey: .typoCorrectionExplanationOtherKey,
                noKey: .typoCorrectionExplanationNoKey)
        case .neverCorrect:
            RestoreKeyWording(
                escape: .neverCorrectExplanation, otherKey: .neverCorrectExplanationOtherKey,
                noKey: .neverCorrectExplanationNoKey)
        default: nil
        }
    }

    /// The explanation's catalog key for the restore key the user has now; `explanation` for the settings whose copy
    /// does not name the key.
    public func explanation(restoreHotkey: HotkeyBinding?) -> CatalogText {
        restoreKeyWording.map { CatalogText($0.key(for: restoreHotkey)) } ?? explanation
    }

    /// The explanation as the row shows it: the app name as the argument where the copy names it, the restore key in
    /// PRD-R78's wording, and the disabled suffix while the setting this one depends on is off (PRD-R80).
    public func explanationText(appName: String, settings: EffectiveSettings, _ localizer: Localizer) -> String {
        let text =
            restoreKeyWording?.text(appName: appName, restoreHotkey: settings.restoreHotkey, localizer)
            ?? localizer.format(explanation, appName)
        guard !isEnabled(in: settings), let disabledSuffix else { return text }
        return text + " " + localizer.string(disabledSuffix)
    }
}
