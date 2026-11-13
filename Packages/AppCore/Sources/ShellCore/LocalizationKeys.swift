// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed keys of the four String Catalogs owned by the shell (ADR 0310, PRD-R62). Views and models refer to copy
// only through these enums, so a test can check that every key the code uses exists in its catalog in vi and
// en with matching format arguments, and that the catalogs hold no dead copy.

/// A key of one String Catalog table.
public protocol LocalizationKey: RawRepresentable, CaseIterable, Sendable where RawValue == String {
    static var table: StringTable { get }
}

extension Localizer {
    public func string<Key: LocalizationKey>(_ key: Key) -> String { string(key.rawValue, table: Key.table) }

    public func format<Key: LocalizationKey>(_ key: Key, _ arguments: any CVarArg...) -> String {
        format(key.rawValue, table: Key.table, arguments: arguments)
    }
}

/// `Localizable` (common words) keys used by the shell.
public enum CommonText: String, LocalizationKey {
    public static var table: StringTable { .common }

    case back = "common.back"
    case `continue` = "common.continue"
    case skip = "common.skip"
    case cancel = "common.cancel"
    case close = "common.close"
    /// VoiceOver hints of a plain Cancel or Close button in an AppKit alert (PRD-R66).
    case cancelHint = "common.cancel.accessibilityHint"
    case closeHint = "common.close.accessibilityHint"
    // Mail draft of the bug report (PRD-R47).
    case mailSubject = "bugReport.mail.subject"
    case mailSubjectNoApp = "bugReport.mail.subject.noApp"
    case mailDescription = "bugReport.mail.description"
    case mailNoDescription = "bugReport.mail.noDescription"
    case mailSummary = "bugReport.mail.summary"
    case mailApp = "bugReport.mail.app"
    case mailSymptom = "bugReport.mail.symptom"
    case mailVersion = "bugReport.mail.version"
    case mailMacOS = "bugReport.mail.macOS"
    case mailMethod = "bugReport.mail.method"
    case mailPracticeField = "bugReport.mail.practiceField"
    case mailPracticeFieldYes = "bugReport.mail.practiceField.yes"
    case mailPracticeFieldNo = "bugReport.mail.practiceField.no"
    case mailPracticeFieldUnknown = "bugReport.mail.practiceField.unknown"
    case mailAttachment = "bugReport.mail.attachment"
    case symptomLostLetters = "bugReport.symptom.lostLetters"
    case symptomDuplicatedLetters = "bugReport.symptom.duplicatedLetters"
    case symptomLettersOutOfOrder = "bugReport.symptom.lettersOutOfOrder"
    case symptomWrongTone = "bugReport.symptom.wrongTone"
    case symptomCannotTypeVietnamese = "bugReport.symptom.cannotTypeVietnamese"
    case symptomNothingTyped = "bugReport.symptom.nothingTyped"
    case symptomLag = "bugReport.symptom.lag"
    case symptomOther = "bugReport.symptom.other"
}

/// `Menu` table: menu items (PRD-R11), icon labels (PRD-R10), hotkey words and HUDs (PRD-R12, PLT-R905).
public enum MenuText: String, LocalizationKey {
    public static var table: StringTable { .menu }

    case modeVietnamese = "menu.mode.vietnamese"
    case modeEnglish = "menu.mode.english"
    case modeHint = "menu.mode.accessibilityHint"
    case methodTelex = "menu.method.telex"
    case methodVNI = "menu.method.vni"
    case methodHint = "menu.method.accessibilityHint"
    case perAppTitle = "menu.perApp.title"
    case perAppHint = "menu.perApp.accessibilityHint"
    case ruleRemember = "menu.perApp.rule.remember"
    case ruleAlwaysEnglish = "menu.perApp.rule.alwaysEnglish"
    case ruleAlwaysVietnamese = "menu.perApp.rule.alwaysVietnamese"
    case ruleIgnore = "menu.perApp.rule.ignore"
    case ruleHint = "menu.perApp.rule.accessibilityHint"
    case perAppReport = "menu.perApp.report"
    case perAppReportHint = "menu.perApp.report.accessibilityHint"
    case macros = "menu.macros"
    case macrosHint = "menu.macros.accessibilityHint"
    case settings = "menu.settings"
    case settingsHint = "menu.settings.accessibilityHint"
    case reportProblem = "menu.reportProblem"
    case reportProblemHint = "menu.reportProblem.accessibilityHint"
    case checkForUpdates = "menu.checkForUpdates"
    case checkForUpdatesHint = "menu.checkForUpdates.accessibilityHint"
    case donate = "menu.donate"
    case donateHint = "menu.donate.accessibilityHint"
    case quit = "menu.quit"
    case quitHint = "menu.quit.accessibilityHint"
    case statusHint = "menu.status.accessibilityHint"
    case statusItemHint = "statusItem.accessibilityHint"
    case iconVietnamese = "icon.vietnamese.accessibilityLabel"
    case iconEnglish = "icon.english.accessibilityLabel"
    case iconIgnoredApp = "icon.ignoredApp.accessibilityLabel"
    case iconSecureInputVietnamese = "icon.secureInputVietnamese.accessibilityLabel"
    case iconSecureInputEnglish = "icon.secureInputEnglish.accessibilityLabel"
    case iconPaused = "icon.paused.accessibilityLabel"
    case iconNotWorking = "icon.notWorking.accessibilityLabel"
    case iconCapturing = "icon.capturing.accessibilityLabel"
    case iconStarting = "icon.starting.accessibilityLabel"
    case iconPausedNoTextFocus = "icon.paused.noTextFocus.accessibilityLabel"
    case iconPausedUserDisabled = "icon.paused.userDisabled.accessibilityLabel"
    case iconPausedSessionInactive = "icon.paused.sessionInactive.accessibilityLabel"
    case iconPausedDiagnosticsTest = "icon.paused.diagnosticsTest.accessibilityLabel"
    case iconNotWorkingFailOpen = "icon.notWorking.failOpen.accessibilityLabel"
    case hotkeySpace = "hotkey.space"
    case hotkeyRight = "hotkey.right"
    case hotkeyUnknownKey = "hotkey.unknownKey"
    case hudVietnameseGlyph = "hud.switch.vietnamese.glyph"
    case hudEnglishGlyph = "hud.switch.english.glyph"
    case hudVietnameseAnnouncement = "hud.switch.vietnamese.announcement"
    case hudEnglishAnnouncement = "hud.switch.english.announcement"
    case captureTitle = "hud.capture.title"
    case captureRemaining = "hud.capture.remaining"
    case captureStop = "hud.capture.stop"
    case captureStopLabel = "hud.capture.stop.accessibilityLabel"
    case captureStopHint = "hud.capture.stop.accessibilityHint"
}

/// `Status` table: status lines and their actions (PRD-R43), secure-input hints (PLT-R397, PLT-R398C).
public enum StatusText: String, LocalizationKey {
    public static var table: StringTable { .status }

    case noPermission = "status.noPermission"
    case builtInFallbackHint = "status.hint.builtInFallback"
    case secureInputHolder = "status.secureInput.holder"
    case secureInputUnknownHolder = "status.secureInput.unknownHolder"
    case secureInputStaleHolder = "status.secureInput.staleHolder"
    case postingBroken = "status.failOpen.postingBroken"
    case tapUnavailable = "status.failOpen.tapUnavailable"
    case watchdog = "status.failOpen.watchdog"
    case callbackStuck = "status.failOpen.callbackStuck"
    case nonLatinSource = "status.nonLatinSource"
    case builtInVietnamese = "status.builtInVietnamese"
    case noTextFocus = "status.noTextFocus"
    case noTextFocusUnknownApp = "status.noTextFocus.unknownApp"
    case userDisabled = "status.userDisabled"
    case tapReenabled = "status.tapReenabled"
    case safeMode = "status.safeMode"
    case settingsCorrupt = "status.settings.corruptFileUsingDefaults"
    case settingsNewerSchema = "status.settings.newerSchemaReadOnly"
    case settingsWriteFailed = "status.settings.writeFailed"
    case knownLimitationNote = "status.knownLimitation.note"
    case knownLimitationGeneric = "status.knownLimitation.generic"
    case actionGrantPermission = "status.action.grantPermission"
    case actionSafeModeChoices = "status.action.safeModeChoices"
    case actionShowHolder = "status.action.showHolder"
    case actionSecureInputHelp = "status.action.secureInputHelp"
    case actionSecureInputHelpUnknownHolder = "status.action.secureInputHelp.unknownHolder"
    case actionReportProblem = "status.action.reportProblem"
    case actionLearnMore = "status.action.learnMore"
    case actionOverrideTextFocus = "status.action.overrideTextFocus"
    case actionReopenApp = "status.action.reopenApp"
    case actionOpenSettings = "status.action.openSettings"
    case hintTerminal = "secureInputHint.terminal.secureKeyboardEntry"
    case hintITerm2 = "secureInputHint.iterm2.secureKeyboardEntry"
    case hintBrowser = "secureInputHint.browser.passwordField"

    /// Prefix of the data-driven secure-input hints: `secureInputHint.<hintKey>` where `hintKey` comes from
    /// `secureInputHints` in compat-rules.json (PLT-R397).
    public static let secureInputHintPrefix = "secureInputHint."

    /// Hint keys the catalog has copy for. A rules hint key outside this set shows no hint rather than a raw key.
    public static let knownSecureInputHintKeys: Set<String> = Set(
        [hintTerminal, hintITerm2, hintBrowser].map { String($0.rawValue.dropFirst(secureInputHintPrefix.count)) })
}

/// `Onboarding` table: the eight screens (PRD-R40), permission help (PLT-R740), move offer (PLT-R710).
public enum OnboardingText: String, LocalizationKey {
    public static var table: StringTable { .onboarding }

    case windowTitle = "onboarding.window.title"
    case welcomeTitle = "onboarding.welcome.title"
    case welcomeBody = "onboarding.welcome.body"
    case welcomeFootnote = "onboarding.welcome.footnote"
    case welcomeStart = "onboarding.welcome.start"
    case permissionTitle = "onboarding.permission.title"
    case permissionBody = "onboarding.permission.body"
    case permissionBulletKeysOnly = "onboarding.permission.bullet.keysOnly"
    case permissionBulletPasswords = "onboarding.permission.bullet.passwords"
    case permissionBulletLocal = "onboarding.permission.bullet.local"
    case permissionInstruction = "onboarding.permission.instruction"
    case permissionOpenPane = "onboarding.permission.openPane"
    case permissionGranted = "onboarding.permission.granted"
    case permissionWaiting = "onboarding.permission.waiting"
    case permissionLost = "onboarding.permission.lost"
    case permissionStale = "onboarding.permission.stale"
    case permissionInputMonitoring = "onboarding.permission.inputMonitoring"
    case permissionRelaunch = "onboarding.permission.relaunch"
    case permissionHelpLink = "onboarding.permission.helpLink"
    case permissionIllustration = "onboarding.permission.illustration"
    case helpTitle = "onboarding.permissionHelp.title"
    case helpStep1 = "onboarding.permissionHelp.step1"
    case helpStep2 = "onboarding.permissionHelp.step2"
    case helpStep3 = "onboarding.permissionHelp.step3"
    case helpResetIntro = "onboarding.permissionHelp.resetIntro"
    case helpReset = "onboarding.permissionHelp.reset"
    case helpResetFailed = "onboarding.permissionHelp.resetFailed"
    case helpConfirmTitle = "onboarding.permissionHelp.confirmTitle"
    case helpConfirmBody = "onboarding.permissionHelp.confirmBody"
    case helpConfirm = "onboarding.permissionHelp.confirm"
    case helpFallback = "onboarding.permissionHelp.fallback"
    case methodTitle = "onboarding.method.title"
    case methodTelexTitle = "onboarding.method.telex.title"
    case methodTelexExample = "onboarding.method.telex.example"
    case methodVNITitle = "onboarding.method.vni.title"
    case methodVNIExample = "onboarding.method.vni.example"
    case methodSelected = "onboarding.method.selected"
    case practicePlaceholder = "onboarding.practice.placeholder"
    case switchingTitle = "onboarding.switching.title"
    case switchingBody = "onboarding.switching.body"
    case switchingPerApp = "onboarding.switching.perApp"
    case switchingEnglishWords = "onboarding.switching.englishWords"
    case switchingChangeKey = "onboarding.switching.changeKey"
    case conflictsTitle = "onboarding.conflicts.title"
    case conflictsBody = "onboarding.conflicts.body"
    case conflictsHowToQuit = "onboarding.conflicts.howToQuit"
    case conflictsCheckAgain = "onboarding.conflicts.checkAgain"
    case conflictsBuiltIn = "onboarding.conflicts.builtIn"
    case conflictsOpenKeyboard = "onboarding.conflicts.openKeyboard"
    case importTitle = "onboarding.import.title"
    case importBody = "onboarding.import.body"
    case importChooseFile = "onboarding.import.chooseFile"
    case importLater = "onboarding.import.later"
    case tryItTitle = "onboarding.tryIt.title"
    case tryItTargetVietnamese = "onboarding.tryIt.target.vietnamese"
    case tryItTargetEnglish = "onboarding.tryIt.target.english"
    case tryItItemVietnamese = "onboarding.tryIt.item.vietnamese"
    case tryItItemEnglish = "onboarding.tryIt.item.english"
    case tryItItemToggle = "onboarding.tryIt.item.toggle"
    case tryItItemDone = "onboarding.tryIt.itemDone"
    case tryItItemPending = "onboarding.tryIt.itemPending"
    case tryItDone = "onboarding.tryIt.done"
    case doneTitle = "onboarding.done.title"
    case doneBody = "onboarding.done.body"
    case doneOpenAtLogin = "onboarding.done.openAtLogin"
    /// macOS 12 (ADR 0315). Arguments: app name, then the System Preferences, Users & Groups and Login Items names.
    case doneOpenAtLoginManual = "onboarding.done.openAtLoginManual"
    case doneStart = "onboarding.done.start"
    case doneArrow = "onboarding.done.arrow"
    case moveTitle = "onboarding.move.title"
    case moveBodyTranslocated = "onboarding.move.body.translocated"
    case moveBodyReadOnlyVolume = "onboarding.move.body.readOnlyVolume"
    case moveBodyOutsideApplications = "onboarding.move.body.outsideApplications"
    case moveConfirm = "onboarding.move.confirm"
    case moveQuit = "onboarding.move.quit"
}

/// Every interactive control of the onboarding window, with its VoiceOver label and hint keys (PRD-R66).
public enum OnboardingControl: String, Sendable, CaseIterable {
    case back, skip, primary, openPermissionPane, openInputMonitoringPane, relaunch, permissionHelp,
        resetPermission, confirmResetPermission, cancelResetPermission, closeHelp, methodTelex, methodVNI,
        practiceField, changeToggleKey, conflictHelp,
        checkAgain, openKeyboardPane, chooseImportFile, importLater, tryItField, openAtLogin, moveConfirm,
        moveQuit

    public var accessibilityLabelKey: String { "onboarding.control.\(rawValue).accessibilityLabel" }
    public var accessibilityHintKey: String { "onboarding.control.\(rawValue).accessibilityHint" }
}
