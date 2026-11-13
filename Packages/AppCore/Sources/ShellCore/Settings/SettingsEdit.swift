// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One change made in the Settings window. Every edit is an explicit user choice, so it is stored as `.set`
// even when it equals today's default (PRD-R6, PLT-R1004), and applies immediately (PRD-R27, PLT-R1008).

public import AppModel
public import SettingsStore

public enum SettingsEdit: Sendable, Hashable {
    case typingMethod(TypingMethod)  // D1
    case tonePlacement(TonePlacement)  // D2
    case englishRestore(Bool)  // D4
    case telexStandaloneW(Bool)  // D5
    case telexBracketKeys(Bool)  // D6
    case restoreHotkey(HotkeyBinding?)  // D8, nil = the user chose none
    case macrosEnabled(Bool)  // D9
    case toggleHotkey(HotkeyBinding)  // D11
    case rememberPerApp(Bool)  // D12
    case showSwitchIndicator(Bool)  // D14
    case soundOnSwitch(Bool)  // D15
    case clickIconToToggle(Bool)  // D16
    case interfaceLanguage(InterfaceLanguage)  // D18
    case automaticallyCheckForUpdates(Bool)  // D19
    case automaticallyInstallUpdates(Bool)  // D20
    case updateChannel(UpdateChannel)  // D21
    case layoutBinding(LayoutModeBinding)  // PLT-R373
    case keepAsTyped(Set<String>)  // ENG-R860
    case keepVietnamese(Set<String>)  // ENG-R860

    public func apply(to settings: inout UserSettings) {
        switch self {
        case .typingMethod(let value): settings.typingMethod = .set(value)
        case .tonePlacement(let value): settings.tonePlacement = .set(value)
        case .englishRestore(let value): settings.englishRestore = .set(value)
        case .telexStandaloneW(let value): settings.telexStandaloneW = .set(value)
        case .telexBracketKeys(let value): settings.telexBracketKeys = .set(value)
        case .restoreHotkey(let value): settings.restoreHotkey = .set(value)
        case .macrosEnabled(let value): settings.macrosEnabled = .set(value)
        case .toggleHotkey(let value): settings.toggleHotkey = .set(value)
        case .rememberPerApp(let value): settings.rememberPerApp = .set(value)
        case .showSwitchIndicator(let value): settings.showSwitchIndicator = .set(value)
        case .soundOnSwitch(let value): settings.soundOnSwitch = .set(value)
        case .clickIconToToggle(let value): settings.clickIconToToggle = .set(value)
        case .interfaceLanguage(let value): settings.interfaceLanguage = .set(value)
        case .automaticallyCheckForUpdates(let value): settings.automaticallyCheckForUpdates = .set(value)
        case .automaticallyInstallUpdates(let value): settings.automaticallyInstallUpdates = .set(value)
        case .updateChannel(let value): settings.updateChannel = .set(value)
        case .layoutBinding(let value): settings.layoutBinding = .set(value)
        case .keepAsTyped(let value): settings.keepAsTyped = value
        case .keepVietnamese(let value): settings.keepVietnamese = value
        }
    }

    /// The setting this edit changes.
    public var item: SettingItem {
        switch self {
        case .typingMethod: .typingMethod
        case .tonePlacement: .tonePlacement
        case .englishRestore: .englishRestore
        case .telexStandaloneW: .telexStandaloneW
        case .telexBracketKeys: .telexBracketKeys
        case .restoreHotkey: .restoreHotkey
        case .macrosEnabled: .macrosEnabled
        case .toggleHotkey: .toggleHotkey
        case .rememberPerApp: .rememberPerApp
        case .showSwitchIndicator: .switchIndicator
        case .soundOnSwitch: .soundOnSwitch
        case .clickIconToToggle: .clickIconToToggle
        case .interfaceLanguage: .interfaceLanguage
        case .automaticallyCheckForUpdates: .automaticallyCheckForUpdates
        case .automaticallyInstallUpdates: .automaticallyInstallUpdates
        case .updateChannel: .updateChannel
        case .layoutBinding: .layoutBinding
        case .keepAsTyped: .keepAsTyped
        case .keepVietnamese: .keepVietnamese
        }
    }
}
