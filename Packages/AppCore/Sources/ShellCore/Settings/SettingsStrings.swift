// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed keys of the `Settings` String Catalog (ADR 0310, PRD-R62, PRD-R66): Settings window chrome, General and
// Typing panes, hotkey recorder, reset, export, import and store notices. A catalog test checks that every key
// exists in vi and en with matching arguments and that the catalog holds no dead copy.

/// `Settings` table keys.
public enum SettingsText: String, LocalizationKey {
    public static var table: StringTable { .settings }

    case windowTitle = "settings.window.title"
    case paneGeneral = "settings.pane.general"
    case paneTyping = "settings.pane.typing"
    case paneApps = "settings.pane.apps"
    case paneMacros = "settings.pane.macros"
    case paneAboutSupport = "settings.pane.aboutSupport"
    case advanced = "settings.advanced"
    case resetPane = "settings.reset.paneButton"
    case openAtLoginTitle = "settings.general.openAtLogin.title"
    case openAtLoginExplanation = "settings.general.openAtLogin.explanation"
    case openAtLoginApproval = "settings.general.openAtLogin.requiresApproval"
    case openAtLoginNotFound = "settings.general.openAtLogin.notFound"
    case openAtLoginFailed = "settings.general.openAtLogin.failed"
    case openSystemSettings = "settings.general.openAtLogin.openSystemSettings"
    case toggleHotkeyTitle = "settings.general.toggleHotkey.title"
    case toggleHotkeyExplanation = "settings.general.toggleHotkey.explanation"
    case rememberPerAppTitle = "settings.general.rememberPerApp.title"
    case rememberPerAppExplanation = "settings.general.rememberPerApp.explanation"
    case switchIndicatorTitle = "settings.general.switchIndicator.title"
    case switchIndicatorExplanation = "settings.general.switchIndicator.explanation"
    case interfaceLanguageTitle = "settings.general.interfaceLanguage.title"
    case interfaceLanguageExplanation = "settings.general.interfaceLanguage.explanation"
    case languageVietnamese = "settings.language.vietnamese"
    case languageEnglish = "settings.language.english"
    case soundOnSwitchTitle = "settings.general.soundOnSwitch.title"
    case soundOnSwitchExplanation = "settings.general.soundOnSwitch.explanation"
    case clickIconTitle = "settings.general.clickIcon.title"
    case clickIconExplanation = "settings.general.clickIcon.explanation"
    case layoutBindingTitle = "settings.general.layoutBinding.title"
    case layoutBindingExplanation = "settings.general.layoutBinding.explanation"
    case layoutBindingNone = "settings.general.layoutBinding.none"
    case layoutBindingVietnamese = "settings.general.layoutBinding.vietnamese"
    case layoutBindingEnglish = "settings.general.layoutBinding.english"
    case layoutBindingEmpty = "settings.general.layoutBinding.empty"
    case layoutBindingIncomplete = "settings.general.layoutBinding.incomplete"
    case hotkeyChange = "settings.hotkey.change"
    case hotkeyRecording = "settings.hotkey.recording"
    case hotkeyCancel = "settings.hotkey.cancel"
    case hotkeyUseDefault = "settings.hotkey.useDefault"
    case hotkeyUseEscape = "settings.hotkey.useEscape"
    case hotkeyClear = "settings.hotkey.clear"
    case hotkeyNotSet = "settings.hotkey.notSet"
    case hotkeyRejectedModifierTap = "settings.hotkey.rejected.modifierTap"
    case hotkeyRejectedRestoreModifierTap = "settings.hotkey.rejected.restoreModifierTap"
    case hotkeyRejectedKeyWithoutModifier = "settings.hotkey.rejected.keyWithoutModifier"
    case hotkeyConflict = "settings.hotkey.conflict"
    case hotkeyConflictHelp = "settings.hotkey.conflict.help"
    case hotkeyConflictHelpPath = "settings.hotkey.conflict.helpPath"
    case conflictSpotlight = "settings.hotkey.feature.spotlight"
    case conflictPreviousSource = "settings.hotkey.feature.previousSource"
    case conflictNextSource = "settings.hotkey.feature.nextSource"
    case conflictCharacterViewer = "settings.hotkey.feature.characterViewer"
    case conflictAppSwitcher = "settings.hotkey.feature.appSwitcher"
    case conflictQuitApp = "settings.hotkey.feature.quitApp"
    case conflictCloseWindow = "settings.hotkey.feature.closeWindow"
    case methodTitle = "settings.typing.method.title"
    case methodExplanation = "settings.typing.method.explanation"
    case methodTelex = "settings.typing.method.telex"
    case methodVNI = "settings.typing.method.vni"
    case practiceLabel = "settings.typing.practice.label"
    case practicePlaceholder = "settings.typing.practice.placeholder"
    case toneTitle = "settings.typing.tone.title"
    case toneExplanation = "settings.typing.tone.explanation"
    case toneTraditional = "settings.typing.tone.traditional"
    case toneModern = "settings.typing.tone.modern"
    case englishRestoreTitle = "settings.typing.englishRestore.title"
    case englishRestoreExplanation = "settings.typing.englishRestore.explanation"
    case keepAsTypedTitle = "settings.typing.keepAsTyped.title"
    case keepAsTypedExplanation = "settings.typing.keepAsTyped.explanation"
    case keepVietnameseTitle = "settings.typing.keepVietnamese.title"
    case keepVietnameseExplanation = "settings.typing.keepVietnamese.explanation"
    case listPlaceholder = "settings.typing.list.placeholder"
    case listAdd = "settings.typing.list.add"
    case listRemove = "settings.typing.list.remove"
    case listEmpty = "settings.typing.list.empty"
    case listInvalid = "settings.typing.list.invalid"
    case listDuplicate = "settings.typing.list.duplicate"
    case standaloneWTitle = "settings.typing.standaloneW.title"
    case standaloneWExplanation = "settings.typing.standaloneW.explanation"
    case bracketsTitle = "settings.typing.brackets.title"
    case bracketsExplanation = "settings.typing.brackets.explanation"
    case restoreHotkeyTitle = "settings.typing.restoreHotkey.title"
    case restoreHotkeyExplanation = "settings.typing.restoreHotkey.explanation"
    case resetTitlePane = "settings.reset.title.pane"
    case resetTitleAll = "settings.reset.title.all"
    case resetBodyGeneral = "settings.reset.body.general"
    case resetBodyTyping = "settings.reset.body.typing"
    case resetBodyApps = "settings.reset.body.apps"
    case resetBodyMacros = "settings.reset.body.macros"
    case resetBodyAll = "settings.reset.body.all"
    case resetIncludeMacros = "settings.reset.includeMacros"
    case resetExportOffer = "settings.reset.exportOffer"
    case resetExportFirst = "settings.reset.exportFirst"
    case resetExported = "settings.reset.exported"
    case resetConfirm = "settings.reset.confirm"
    case resetCancel = "settings.reset.cancel"
    case exportTitle = "settings.export.title"
    case exportBody = "settings.export.body"
    case exportIncludeMacros = "settings.export.includeMacros"
    case exportMacrosNote = "settings.export.macrosNote"
    case exportIncludeAppModes = "settings.export.includeAppModes"
    case exportSave = "settings.export.save"
    case exportCancel = "settings.export.cancel"
    case exportFailed = "settings.export.failed"
    case exportDone = "settings.export.done"
    case importTitle = "settings.import.title"
    case importSettingsChanged = "settings.import.settingsChanged"
    case importNoSettingsChanged = "settings.import.noSettingsChanged"
    case importAppEntries = "settings.import.appEntries"
    case importRuleOverrides = "settings.import.ruleOverrides"
    case importMacros = "settings.import.macros"
    case importSkipped = "settings.import.skipped"
    case importNewerSchema = "settings.import.newerSchema"
    case importBackupNote = "settings.import.backupNote"
    case importApplySettings = "settings.import.apply.settings"
    case importApplyAppModes = "settings.import.apply.appModes"
    case importApplyRuleOverrides = "settings.import.apply.ruleOverrides"
    case importApplyMacros = "settings.import.apply.macros"
    case importDuplicatesTitle = "settings.import.duplicates"
    case importKeepMine = "settings.import.keepMine"
    case importUseImported = "settings.import.useImported"
    case importConfirm = "settings.import.confirm"
    case importCancel = "settings.import.cancel"
    case importChooseOther = "settings.import.chooseOther"
    case importDone = "settings.import.done"
    case importErrorTooLarge = "settings.import.error.tooLarge"
    case importErrorFormat = "settings.import.error.format"
    case importErrorNotExport = "settings.import.error.notExport"
    case importErrorVersion = "settings.import.error.version"
    case importErrorSection = "settings.import.error.section"
    case importErrorMigration = "settings.import.error.migration"
    case importErrorSafeMode = "settings.import.error.safeMode"
    case importErrorUnreadable = "settings.import.error.unreadable"
    case nameFirstSeenAppMode = "settings.name.firstSeenAppMode"
    case nameMacrosInEnglishMode = "settings.name.macrosInEnglishMode"
    case nameOptedInRules = "settings.name.optedInRules"
    case noticeRecovered = "settings.notice.recoveredFromBackup"
    case noticeCorrupt = "settings.notice.corruptFileUsingDefaults"
    case noticeNewerSchema = "settings.notice.newerSchemaReadOnly"
    case noticeSafeMode = "settings.notice.safeMode"
    case noticeWriteFailed = "settings.notice.writeFailed"
    case noticeDismiss = "settings.notice.dismiss"
    case noticeUseDefaults = "settings.notice.useDefaults"
    case noticeLeaveSafeMode = "settings.notice.leaveSafeMode"
    case noticeReport = "settings.notice.report"
    case noticeReset = "settings.notice.reset"
}

/// Every interactive control that uses the `Settings` table, with its VoiceOver label and hint (PRD-R66).
public enum SettingsControl: String, AccessibleControl {
    public static var table: StringTable { .settings }
    public static var keyPrefix: String { "settings" }

    case panePicker
    case openAtLogin
    case openSystemSettings
    case toggleHotkeyChange
    case toggleHotkeyCancel
    case toggleHotkeyDefault
    case restoreHotkeyChange
    case restoreHotkeyCancel
    case restoreHotkeyEscape
    case restoreHotkeyClear
    case hotkeyConflictHelp
    case rememberPerApp
    case switchIndicator
    case interfaceLanguage
    case advancedDisclosure
    case soundOnSwitch
    case clickIconToToggle
    case layoutBindingEnabled
    case layoutBindingAssignment
    case typingMethod
    case practiceField
    case tonePlacement
    case englishRestore
    case keepAsTypedField
    case keepAsTypedAdd
    case keepVietnameseField
    case keepVietnameseAdd
    case wordRemove
    case standaloneW
    case bracketKeys
    case resetPane
    case resetIncludeMacros
    case resetExportFirst
    case resetConfirm
    case resetCancel
    case exportIncludeMacros
    case exportIncludeAppModes
    case exportSave
    case exportCancel
    case importApplySettings
    case importApplyAppModes
    case importApplyRuleOverrides
    case importApplyMacros
    case importDuplicates
    case importConfirm
    case importCancel
    case importChooseOther
    case noticeDismiss
    case noticeUseDefaults
    case noticeLeaveSafeMode
    case noticeReport
    case noticeReset
}
