// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the Settings window shows (PRD-R7, PRD-R24, PRD-R25): seven panes in a fixed order, the settings of each
// pane with a title and a one-line explanation, and the defaults that are deliberately not settings.

public import SettingsStore

/// The seven panes, in PRD-R24 order (Pa, 15/11/2026: About & Support split into About, Support and Licences).
public enum SettingsPaneKind: String, Sendable, Hashable, CaseIterable {
    case general, typing, apps, macros, about, support, licences

    public var title: SettingsText {
        switch self {
        case .general: .paneGeneral
        case .typing: .paneTyping
        case .apps: .paneApps
        case .macros: .paneMacros
        case .about: .paneAbout
        case .support: .paneSupport
        case .licences: .paneLicences
        }
    }

    /// The pane's own reset (PRD-R26). Support hosts the global reset instead; About and Licences have nothing to reset.
    public var paneReset: PaneReset? {
        switch self {
        case .general: .general
        case .typing: .typing
        case .apps: .apps
        case .macros: .macros
        case .about, .support, .licences: nil
        }
    }

    /// Panes with a "Tùy chọn nâng cao" disclosure (PRD-R24).
    public var hasAdvancedSection: Bool { !SettingItem.allCases.filter { $0.pane == self && $0.isAdvanced }.isEmpty }
}

/// Every setting the window exposes. Per-app rules and compatibility modes are data, not settings (principle 5),
/// and live in the Apps pane rows.
public enum SettingItem: String, Sendable, Hashable, CaseIterable {
    // General (PRD-R24)
    case openAtLogin, toggleHotkey, rememberPerApp, switchIndicator, interfaceLanguage
    case soundOnSwitch, clickIconToToggle, layoutBinding
    // Typing (PRD-R24)
    case typingMethod, tonePlacement, englishRestore, keepAsTyped, keepVietnamese
    case telexStandaloneW, telexBracketKeys, restoreHotkey
    // Macros (section 8)
    case macrosEnabled
    // About (D19 to D21)
    case updateChannel, automaticallyCheckForUpdates, automaticallyInstallUpdates

    public var pane: SettingsPaneKind {
        switch self {
        case .openAtLogin, .toggleHotkey, .rememberPerApp, .switchIndicator, .interfaceLanguage, .soundOnSwitch,
            .clickIconToToggle, .layoutBinding:
            .general
        case .typingMethod, .tonePlacement, .englishRestore, .keepAsTyped, .keepVietnamese, .telexStandaloneW,
            .telexBracketKeys, .restoreHotkey:
            .typing
        case .macrosEnabled: .macros
        case .updateChannel, .automaticallyCheckForUpdates, .automaticallyInstallUpdates: .about
        }
    }

    /// Behind "Tùy chọn nâng cao" (PRD-R24): D15, D16, PLT-R373 binding, D5, D6, D8.
    public var isAdvanced: Bool {
        switch self {
        case .soundOnSwitch, .clickIconToToggle, .layoutBinding, .telexStandaloneW, .telexBracketKeys, .restoreHotkey:
            true
        default: false
        }
    }

    /// Row of the defaults table of 03-product.md section 4, or the requirement for settings outside it.
    public var requirement: String {
        switch self {
        case .typingMethod: "D1"
        case .tonePlacement: "D2"
        case .englishRestore: "D4"
        case .telexStandaloneW: "D5"
        case .telexBracketKeys: "D6"
        case .restoreHotkey: "D8"
        case .macrosEnabled: "D9"
        case .toggleHotkey: "D11"
        case .rememberPerApp: "D12"
        case .switchIndicator: "D14"
        case .soundOnSwitch: "D15"
        case .clickIconToToggle: "D16"
        case .openAtLogin: "D17"
        case .interfaceLanguage: "D18"
        case .automaticallyCheckForUpdates: "D19"
        case .automaticallyInstallUpdates: "D20"
        case .updateChannel: "D21"
        case .layoutBinding: "PLT-R373"
        case .keepAsTyped, .keepVietnamese: "ENG-R860"
        }
    }

    /// The `settings.json` key (`SettingFields`), or nil for D17 (`SMAppService` is the source of truth) and the
    /// two word lists (plain sets in `UserSettings`).
    public var settingsKey: String? {
        switch self {
        case .openAtLogin: nil
        case .toggleHotkey: "toggleHotkey"
        case .rememberPerApp: "rememberPerApp"
        case .switchIndicator: "showSwitchIndicator"
        case .interfaceLanguage: "interfaceLanguage"
        case .soundOnSwitch: "soundOnSwitch"
        case .clickIconToToggle: "clickIconToToggle"
        case .layoutBinding: "layoutBinding"
        case .typingMethod: "typingMethod"
        case .tonePlacement: "tonePlacement"
        case .englishRestore: "englishRestore"
        case .keepAsTyped: "keepAsTyped"
        case .keepVietnamese: "keepVietnamese"
        case .telexStandaloneW: "telexStandaloneW"
        case .telexBracketKeys: "telexBracketKeys"
        case .restoreHotkey: "restoreHotkey"
        case .macrosEnabled: "macrosEnabled"
        case .updateChannel: "updateChannel"
        case .automaticallyCheckForUpdates: "automaticallyCheckForUpdates"
        case .automaticallyInstallUpdates: "automaticallyInstallUpdates"
        }
    }

    public var title: CatalogText {
        switch self {
        case .openAtLogin: CatalogText(SettingsText.openAtLoginTitle)
        case .toggleHotkey: CatalogText(SettingsText.toggleHotkeyTitle)
        case .rememberPerApp: CatalogText(SettingsText.rememberPerAppTitle)
        case .switchIndicator: CatalogText(SettingsText.switchIndicatorTitle)
        case .interfaceLanguage: CatalogText(SettingsText.interfaceLanguageTitle)
        case .soundOnSwitch: CatalogText(SettingsText.soundOnSwitchTitle)
        case .clickIconToToggle: CatalogText(SettingsText.clickIconTitle)
        case .layoutBinding: CatalogText(SettingsText.layoutBindingTitle)
        case .typingMethod: CatalogText(SettingsText.methodTitle)
        case .tonePlacement: CatalogText(SettingsText.toneTitle)
        case .englishRestore: CatalogText(SettingsText.englishRestoreTitle)
        case .keepAsTyped: CatalogText(SettingsText.keepAsTypedTitle)
        case .keepVietnamese: CatalogText(SettingsText.keepVietnameseTitle)
        case .telexStandaloneW: CatalogText(SettingsText.standaloneWTitle)
        case .telexBracketKeys: CatalogText(SettingsText.bracketsTitle)
        case .restoreHotkey: CatalogText(SettingsText.restoreHotkeyTitle)
        case .macrosEnabled: CatalogText(MacrosText.enabledTitle)
        case .updateChannel: CatalogText(SupportText.channelTitle)
        case .automaticallyCheckForUpdates: CatalogText(SupportText.autoCheckTitle)
        case .automaticallyInstallUpdates: CatalogText(SupportText.autoInstallTitle)
        }
    }

    /// PRD-R25: the one-line explanation under the setting.
    public var explanation: CatalogText {
        switch self {
        case .openAtLogin: CatalogText(SettingsText.openAtLoginExplanation)
        case .toggleHotkey: CatalogText(SettingsText.toggleHotkeyExplanation)
        case .rememberPerApp: CatalogText(SettingsText.rememberPerAppExplanation)
        case .switchIndicator: CatalogText(SettingsText.switchIndicatorExplanation)
        case .interfaceLanguage: CatalogText(SettingsText.interfaceLanguageExplanation)
        case .soundOnSwitch: CatalogText(SettingsText.soundOnSwitchExplanation)
        case .clickIconToToggle: CatalogText(SettingsText.clickIconExplanation)
        case .layoutBinding: CatalogText(SettingsText.layoutBindingExplanation)
        case .typingMethod: CatalogText(SettingsText.methodExplanation)
        case .tonePlacement: CatalogText(SettingsText.toneExplanation)
        case .englishRestore: CatalogText(SettingsText.englishRestoreExplanation)
        case .keepAsTyped: CatalogText(SettingsText.keepAsTypedExplanation)
        case .keepVietnamese: CatalogText(SettingsText.keepVietnameseExplanation)
        case .telexStandaloneW: CatalogText(SettingsText.standaloneWExplanation)
        case .telexBracketKeys: CatalogText(SettingsText.bracketsExplanation)
        case .restoreHotkey: CatalogText(SettingsText.restoreHotkeyExplanation)
        case .macrosEnabled: CatalogText(MacrosText.enabledExplanation)
        case .updateChannel: CatalogText(SupportText.channelExplanation)
        case .automaticallyCheckForUpdates: CatalogText(SupportText.autoCheckExplanation)
        case .automaticallyInstallUpdates: CatalogText(SupportText.autoInstallExplanation)
        }
    }
}

/// Defaults that MUST NOT appear in the UI (PRD-R7), with the reason. Documented on the website FAQ.
public enum HiddenDefault: String, Sendable, Hashable, CaseIterable {
    case toneMarksAnywhere = "D3"  // always on, not a setting (ENG-R107)
    case quickConsonantShortcuts = "D7"  // not offered (ENG-R121)
    case macrosInEnglishMode = "D10"  // hidden until the engine offers literal mode (ADR 0306)
    case firstSeenAppMode = "D13"  // no control in v1 (UserSettings)
    case pauseForOtherInputSources = "D22"  // always on
    case secureInput = "D23"  // always pass through
    case keyboardLayout = "D24"  // follows macOS
    case outputEncoding = "D25"  // Unicode NFC
    case typingTrace = "D26"  // an on-demand action in Diagnostics, not a setting
    case iCloudSync = "D27"  // not in v1
}

public enum SettingsCatalog {
    /// Settings of `pane` in display order; `advanced` selects the disclosure's content (PRD-R24).
    public static func items(in pane: SettingsPaneKind, advanced: Bool) -> [SettingItem] {
        SettingItem.allCases.filter { $0.pane == pane && $0.isAdvanced == advanced }
    }
}

/// PRD-R24: an Advanced disclosure is collapsed by default and remembered once expanded. Stored in the app's
/// user defaults (window state, not a preference, ADR 0307), keyed per pane.
public struct AdvancedDisclosureMemory: Sendable {
    let store: any KeyValueStore
    public init(store: any KeyValueStore) { self.store = store }

    public static func key(for pane: SettingsPaneKind) -> String { "settings.advancedExpanded.\(pane.rawValue)" }

    public func isExpanded(_ pane: SettingsPaneKind) -> Bool { store.integer(forKey: Self.key(for: pane)) == 1 }

    public func setExpanded(_ expanded: Bool, for pane: SettingsPaneKind) {
        store.set(expanded ? 1 : 0, forKey: Self.key(for: pane))
    }
}
