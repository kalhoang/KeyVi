// SPDX-License-Identifier: GPL-3.0-or-later
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
    case paneAbout = "settings.pane.about"
    case paneSupport = "settings.pane.support"
    case paneLicences = "settings.pane.licences"
    case advanced = "settings.advanced"
    case resetPane = "settings.reset.paneButton"
    /// The row beside the per-pane reset button (PRD-R26).
    case resetPaneExplanation = "settings.reset.paneExplanation"
    /// Grouped section headers (`SettingsCatalog.sections`, W8-D).
    case sectionStartup = "settings.section.startup"
    case sectionSwitching = "settings.section.switching"
    case sectionLanguage = "settings.section.language"
    case sectionVietnamese = "settings.section.vietnamese"
    case sectionEnglish = "settings.section.english"
    case openAtLoginTitle = "settings.general.openAtLogin.title"
    case openAtLoginExplanation = "settings.general.openAtLogin.explanation"
    case openAtLoginApproval = "settings.general.openAtLogin.requiresApproval"
    case openAtLoginNotFound = "settings.general.openAtLogin.notFound"
    case openAtLoginFailed = "settings.general.openAtLogin.failed"
    case openSystemSettings = "settings.general.openAtLogin.openSystemSettings"
    /// macOS 12 (ADR 0315). Arguments: app name, then the System Preferences, Users & Groups and Login Items names.
    case openAtLoginManual = "settings.general.openAtLogin.manual"
    case openSystemPreferences = "settings.general.openAtLogin.openSystemPreferences"
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
    /// ENG-R862, next to a learned entry. Argument: the app's name.
    case listLearnedIn = "settings.typing.list.learnedIn"
    /// ENG-R862, help and VoiceOver label of the "use in every app" button. Argument: the word.
    case listMakeGlobal = "settings.typing.list.makeGlobal"
    /// ENG-R862, under the lists when at least one entry was learned.
    case listLearnedNote = "settings.typing.list.learnedNote"
    /// D28 (PRD-R79). The explanation's argument is the app name.
    case learnCollisionTitle = "settings.typing.learnCollision.title"
    case learnCollisionExplanation = "settings.typing.learnCollision.explanation"
    /// D28 row button that opens the learned-words sheet (PRD-R78).
    case learnedChoicesShow = "settings.typing.learnedChoices.show"
    /// The learned-words sheet (PRD-R78, PRD-R79). The empty state and the clear-all body take the app name.
    case learnedChoicesTitle = "settings.typing.learnedChoices.title"
    case learnedChoicesIntro = "settings.typing.learnedChoices.intro"
    case learnedChoicesEmpty = "settings.typing.learnedChoices.empty"
    /// The empty state when D8 is another key (its name is the second argument) or off (ENG-R864: strong signals
    /// come from the restore toggle).
    case learnedChoicesEmptyOtherKey = "settings.typing.learnedChoices.emptyOtherKey"
    case learnedChoicesEmptyNoKey = "settings.typing.learnedChoices.emptyNoKey"
    /// The memory is not loaded (the bundled lists failed, PLT-R914); argument: the app name.
    case learnedChoicesUnavailable = "settings.typing.learnedChoices.unavailable"
    case learnedChoicesRemoveAll = "settings.typing.learnedChoices.removeAll"
    case learnedChoicesDone = "settings.typing.learnedChoices.done"
    /// The context class of a row in words (ENG-R863): sentence start, after a Vietnamese, English or neutral word.
    case learnedContextSentenceStart = "settings.typing.learnedChoices.context.sentenceStart"
    case learnedContextAfterVietnamese = "settings.typing.learnedChoices.context.afterVietnamese"
    case learnedContextAfterEnglish = "settings.typing.learnedChoices.context.afterEnglish"
    case learnedContextAfterNeutral = "settings.typing.learnedChoices.context.afterNeutral"
    case learnedContextAny = "settings.typing.learnedChoices.context.any"
    /// VoiceOver text of a row. Arguments: the word, its Vietnamese reading, the context (Vietnamese choice); the
    /// word and the context (English choice).
    case learnedRowVietnamese = "settings.typing.learnedChoices.row.vietnamese"
    case learnedRowEnglish = "settings.typing.learnedChoices.row.english"
    /// "Xóa tất cả" confirmation (PRD-R78). The body's argument is the app name.
    case learnedClearTitle = "settings.typing.learnedChoices.clear.title"
    case learnedClearBody = "settings.typing.learnedChoices.clear.body"
    case learnedClearConfirm = "settings.typing.learnedChoices.clear.confirm"
    case learnedClearCancel = "settings.typing.learnedChoices.clear.cancel"
    case standaloneWTitle = "settings.typing.standaloneW.title"
    case standaloneWExplanation = "settings.typing.standaloneW.explanation"
    case bracketsTitle = "settings.typing.brackets.title"
    case bracketsExplanation = "settings.typing.brackets.explanation"
    case restoreHotkeyTitle = "settings.typing.restoreHotkey.title"
    case restoreHotkeyExplanation = "settings.typing.restoreHotkey.explanation"
    case restoreHotkeySwitch = "settings.typing.restoreHotkey.switch"
    /// D29 (PRD-R79), under Advanced.
    case lookaheadRevisionTitle = "settings.typing.lookaheadRevision.title"
    case lookaheadRevisionExplanation = "settings.typing.lookaheadRevision.explanation"
    /// The never-correct list (1.1.0, PRD-R81, ENG-R1118), the third list of the English section. The explanation
    /// names the restore key of D8 as PRD-R78 does: Escape (`neverCorrectExplanation`), another key in words
    /// (`OtherKey`: the app name, then the key) or that the key is off (`NoKey`); its first argument is the app name.
    case neverCorrectTitle = "settings.typing.neverCorrect.title"
    case neverCorrectExplanation = "settings.typing.neverCorrect.explanation"
    case neverCorrectExplanationOtherKey = "settings.typing.neverCorrect.explanationOtherKey"
    case neverCorrectExplanationNoKey = "settings.typing.neverCorrect.explanationNoKey"
    /// Under the list's field when an entry is not lowercase letters without marks (PRD-R81).
    case neverCorrectInvalid = "settings.typing.neverCorrect.invalid"
    /// D30 (1.1.0, PRD-R80), right under D28; the explanation's variants and arguments are the list's. The suffix ends
    /// the explanation while D4 is off and the row is disabled.
    case typoCorrectionTitle = "settings.typing.typoCorrection.title"
    case typoCorrectionExplanation = "settings.typing.typoCorrection.explanation"
    case typoCorrectionExplanationOtherKey = "settings.typing.typoCorrection.explanationOtherKey"
    case typoCorrectionExplanationNoKey = "settings.typing.typoCorrection.explanationNoKey"
    case typoCorrectionDisabledSuffix = "settings.typing.typoCorrection.disabledSuffix"
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
    /// The learned collision choices in the export (PLT-R914, PRD-R72).
    case exportIncludeLearnedChoices = "settings.export.includeLearnedChoices"
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
    /// Argument: the number of learned-word entries that will be imported (PRD-R72).
    case importLearnedChoices = "settings.import.learnedChoices"
    /// Arguments: the entries that will be imported, then the entries left out.
    case importLearnedChoicesSkipped = "settings.import.learnedChoicesSkipped"
    /// The learned words cannot be imported while the memory is not loaded; argument: the app name.
    case importLearnedChoicesUnavailable = "settings.import.learnedChoicesUnavailable"
    case importSkipped = "settings.import.skipped"
    case importNewerSchema = "settings.import.newerSchema"
    case importBackupNote = "settings.import.backupNote"
    case importApplySettings = "settings.import.apply.settings"
    case importApplyAppModes = "settings.import.apply.appModes"
    case importApplyRuleOverrides = "settings.import.apply.ruleOverrides"
    case importApplyMacros = "settings.import.apply.macros"
    case importApplyLearnedChoices = "settings.import.apply.learnedChoices"
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
    case nameLearnedWords = "settings.name.learnedWords"
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
    case openSystemPreferences  // macOS 12 (ADR 0315)
    case toggleHotkeyChange
    case toggleHotkeyCancel
    case toggleHotkeyDefault
    case restoreHotkeyChange
    case restoreHotkeyCancel
    case restoreHotkeyEscape
    case restoreHotkeySwitch
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
    case neverCorrectField  // PRD-R81
    case neverCorrectAdd
    case wordRemove
    case wordMakeGlobal  // ENG-R862
    case learnCollisionChoices  // D28
    case typoCorrection  // D30
    case learnedChoicesShow  // PRD-R78
    case learnedChoiceRemove
    case learnedChoicesRemoveAll
    case learnedChoicesDone
    case learnedClearConfirm
    case learnedClearCancel
    case standaloneW
    case bracketKeys
    case lookaheadRevision  // D29
    case resetPane
    case resetIncludeMacros
    case resetExportFirst
    case resetConfirm
    case resetCancel
    case exportIncludeMacros
    case exportIncludeAppModes
    case exportIncludeLearnedChoices
    case exportSave
    case exportCancel
    case importApplySettings
    case importApplyAppModes
    case importApplyRuleOverrides
    case importApplyMacros
    case importApplyLearnedChoices
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
