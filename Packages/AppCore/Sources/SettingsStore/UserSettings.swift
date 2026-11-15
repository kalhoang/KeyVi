// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings.json payload (PLT-R1001). Only explicit user choices are persisted; defaults live in code
// (`DefaultSettings`) and rules (PLT-R1004). Keys are the JSON names below and MUST NOT be renamed without a
// migration (PLT-R1005).

public import AppModel

/// Explicit choices (`settings` object of settings.json). D-numbers refer to 03-product.md section 4.
public struct UserSettings: Sendable, Hashable {
    public var typingMethod: Setting<TypingMethod> = .unset  // D1 "typingMethod"
    public var tonePlacement: Setting<TonePlacement> = .unset  // D2 "tonePlacement"
    public var englishRestore: Setting<Bool> = .unset  // D4 "englishRestore"
    public var telexStandaloneW: Setting<Bool> = .unset  // D5 "telexStandaloneW"
    public var telexBracketKeys: Setting<Bool> = .unset  // D6 "telexBracketKeys"
    public var restoreHotkey: Setting<HotkeyBinding?> = .unset  // D8 "restoreHotkey" (null = none)
    public var macrosEnabled: Setting<Bool> = .unset  // D9 "macrosEnabled"
    public var macrosInEnglishMode: Setting<Bool> = .unset  // D10 "macrosInEnglishMode"
    public var toggleHotkey: Setting<HotkeyBinding> = .unset  // D11 "toggleHotkey"
    public var rememberPerApp: Setting<Bool> = .unset  // D12 "rememberPerApp"
    public var firstSeenAppMode: Setting<FirstSeenMode> = .unset  // D13 "firstSeenAppMode" (no UI in v1)
    public var showSwitchIndicator: Setting<Bool> = .unset  // D14 "showSwitchIndicator"
    public var soundOnSwitch: Setting<Bool> = .unset  // D15 "soundOnSwitch"
    public var clickIconToToggle: Setting<Bool> = .unset  // D16 "clickIconToToggle"
    public var interfaceLanguage: Setting<InterfaceLanguage> = .unset  // D18 "interfaceLanguage"
    public var automaticallyCheckForUpdates: Setting<Bool> = .unset  // D19
    public var automaticallyInstallUpdates: Setting<Bool> = .unset  // D20
    public var updateChannel: Setting<UpdateChannel> = .unset  // D21
    public var layoutBinding: Setting<LayoutModeBinding> = .unset  // PLT-R373 "layoutBinding"
    /// D28 "learnCollisionChoices": learn which reading of a collision word the user chooses (ENG-R863, PLT-R914).
    public var learnCollisionChoices: Setting<Bool> = .unset
    /// D29 "lookaheadRevision": revise the previous word once the next word shows the language (ENG-R828,
    /// PLT-R357). ANDed per app with the rule's `features.lookaheadRevision`.
    public var lookaheadRevision: Setting<Bool> = .unset

    /// ENG-R860 user lists, keyed by lowercased raw keys ("englishRestoreLists" object). User-authored
    /// settings, allowed on disk (PLT-R901 a).
    public var keepAsTyped: Set<String> = []
    public var keepVietnamese: Set<String> = []
    /// ENG-R862: words learned from the user's toggles, each applying only in its app (`englishRestoreLists`
    /// `learnedWords`). `keepAsTyped` and `keepVietnamese` above are the global entries.
    public var learnedWords: Set<LearnedWord> = []
    /// Shipped rules with `requiresUserOptIn: true` that the user enabled (PLT-R460) ("optedInRules").
    public var optedInRules: Set<RuleID> = []
    /// "onboarding" object (PRD-R42).
    public var onboarding = OnboardingState()

    public init() {}

    /// Names of keys that are explicitly set, for the content-free diagnostics report: the JSON names of set
    /// `Setting` values in declaration order, then `keepAsTyped`, `keepVietnamese`, `learnedWords`, `optedInRules`
    /// when non-empty. Names only, never values or apps (PLT-R901, PRD-R6, ADR 0314).
    public var explicitlySetKeys: [String] {
        let settings = SettingFields.all.filter { $0.isSet(self) }.map(\.key)
        let lists = [
            (SettingListKey.keepAsTyped, keepAsTyped.isEmpty), (SettingListKey.keepVietnamese, keepVietnamese.isEmpty),
            (SettingListKey.learnedWords, learnedWords.isEmpty), (SettingListKey.optedInRules, optedInRules.isEmpty),
        ]
        return settings + lists.filter { !$0.1 }.map(\.0)
    }
}

/// D17 (open at login) is deliberately absent: `SMAppService.mainApp` status is the source of truth.

/// PLT-R373: ASCII-capable layouts designated as VI or EN; when enabled the selected source decides the mode.
public struct LayoutModeBinding: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var vietnamese: [InputSourceID]
    public var english: [InputSourceID]
    public init(enabled: Bool = false, vietnamese: [InputSourceID] = [], english: [InputSourceID] = []) {
        self.enabled = enabled
        self.vietnamese = vietnamese
        self.english = english
    }
}

public struct OnboardingState: Sendable, Hashable, Codable {
    /// App version that completed onboarding; nil = never completed (PRD-R40, PRD-R42).
    public var completedVersion: String?
    public init(completedVersion: String? = nil) { self.completedVersion = completedVersion }
}

/// Resolved values the rest of the app consumes. Never persisted.
public struct EffectiveSettings: Sendable, Hashable {
    public var typingMethod: TypingMethod
    public var tonePlacement: TonePlacement
    public var englishRestore: Bool
    public var telexStandaloneW: Bool
    public var telexBracketKeys: Bool
    public var restoreHotkey: HotkeyBinding?
    public var macrosEnabled: Bool
    public var macrosInEnglishMode: Bool
    public var toggleHotkey: HotkeyBinding
    public var rememberPerApp: Bool
    public var firstSeenAppMode: FirstSeenMode
    public var showSwitchIndicator: Bool
    public var soundOnSwitch: Bool
    public var clickIconToToggle: Bool
    public var interfaceLanguage: InterfaceLanguage
    public var automaticallyCheckForUpdates: Bool
    public var automaticallyInstallUpdates: Bool
    public var updateChannel: UpdateChannel
    public var layoutBinding: LayoutModeBinding
    public var learnCollisionChoices: Bool
    public var lookaheadRevision: Bool
    public var keepAsTyped: Set<String>
    public var keepVietnamese: Set<String>
    public var optedInRules: Set<RuleID>
}

/// The shipped defaults (PRD-R5). Changing one after 1.0 needs a decision record and a release note.
public enum DefaultSettings {
    public static let v1 = EffectiveSettings(
        typingMethod: .telex,  // D1
        tonePlacement: .traditional,  // D2
        englishRestore: true,  // D4
        telexStandaloneW: true,  // D5
        telexBracketKeys: false,  // D6
        restoreHotkey: .key(.escape),  // D8 Escape; an explicit null (the off switch) stays none (Q14, 13/11/2026)
        macrosEnabled: true,  // D9
        macrosInEnglishMode: false,  // D10
        toggleHotkey: .defaultToggle,  // D11 tap Control+Shift
        rememberPerApp: true,  // D12
        firstSeenAppMode: .inherit,  // D13
        showSwitchIndicator: true,  // D14
        soundOnSwitch: false,  // D15
        clickIconToToggle: false,  // D16
        interfaceLanguage: .vietnamese,  // D18
        automaticallyCheckForUpdates: true,  // D19
        automaticallyInstallUpdates: true,  // D20
        updateChannel: .stable,  // D21
        layoutBinding: LayoutModeBinding(),
        learnCollisionChoices: true,  // D28 on (decision of the product owner, 15/11/2026)
        lookaheadRevision: true,  // D29 on, also at Return in chat apps (decision of the product owner, 15/11/2026)
        keepAsTyped: [],
        keepVietnamese: [],
        optedInRules: []
    )
}

extension UserSettings {
    public func resolved(over defaults: EffectiveSettings = DefaultSettings.v1) -> EffectiveSettings {
        EffectiveSettings(
            typingMethod: typingMethod.resolved(default: defaults.typingMethod),
            tonePlacement: tonePlacement.resolved(default: defaults.tonePlacement),
            englishRestore: englishRestore.resolved(default: defaults.englishRestore),
            telexStandaloneW: telexStandaloneW.resolved(default: defaults.telexStandaloneW),
            telexBracketKeys: telexBracketKeys.resolved(default: defaults.telexBracketKeys),
            restoreHotkey: restoreHotkey.resolved(default: defaults.restoreHotkey),
            macrosEnabled: macrosEnabled.resolved(default: defaults.macrosEnabled),
            macrosInEnglishMode: macrosInEnglishMode.resolved(default: defaults.macrosInEnglishMode),
            toggleHotkey: toggleHotkey.resolved(default: defaults.toggleHotkey),
            rememberPerApp: rememberPerApp.resolved(default: defaults.rememberPerApp),
            firstSeenAppMode: firstSeenAppMode.resolved(default: defaults.firstSeenAppMode),
            showSwitchIndicator: showSwitchIndicator.resolved(default: defaults.showSwitchIndicator),
            soundOnSwitch: soundOnSwitch.resolved(default: defaults.soundOnSwitch),
            clickIconToToggle: clickIconToToggle.resolved(default: defaults.clickIconToToggle),
            interfaceLanguage: interfaceLanguage.resolved(default: defaults.interfaceLanguage),
            automaticallyCheckForUpdates: automaticallyCheckForUpdates.resolved(
                default: defaults.automaticallyCheckForUpdates),
            automaticallyInstallUpdates: automaticallyInstallUpdates.resolved(
                default: defaults.automaticallyInstallUpdates),
            updateChannel: updateChannel.resolved(default: defaults.updateChannel),
            layoutBinding: layoutBinding.resolved(default: defaults.layoutBinding),
            learnCollisionChoices: learnCollisionChoices.resolved(default: defaults.learnCollisionChoices),
            lookaheadRevision: lookaheadRevision.resolved(default: defaults.lookaheadRevision),
            keepAsTyped: keepAsTyped,
            keepVietnamese: keepVietnamese,
            optedInRules: optedInRules
        )
    }
}
