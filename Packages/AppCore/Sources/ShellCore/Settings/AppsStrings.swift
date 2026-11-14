// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed keys of the `Apps` String Catalog (ADR 0310, PRD-R62, PRD-R66): Apps pane and app detail sheet
// (PRD-R34-R38). A catalog test checks that every key exists in vi and en with matching arguments and that the
// catalog holds no dead copy.

/// `Apps` table keys.
public enum AppsText: String, LocalizationKey {
    public static var table: StringTable { .apps }

    case explanation = "apps.explanation"
    case empty = "apps.empty"
    case columnApp = "apps.column.app"
    case columnRule = "apps.column.rule"
    case columnRemembered = "apps.column.remembered"
    case columnStatus = "apps.column.status"
    case ruleRemember = "apps.rule.remember"
    case ruleAlwaysEnglish = "apps.rule.alwaysEnglish"
    case ruleAlwaysVietnamese = "apps.rule.alwaysVietnamese"
    case ruleIgnore = "apps.rule.ignore"
    case modeVietnamese = "apps.mode.vietnamese"
    case modeEnglish = "apps.mode.english"
    case modeNone = "apps.mode.none"
    case statusWorks = "apps.status.works"
    case statusWorksWithNotes = "apps.status.worksWithNotes"
    case statusNotVerified = "apps.status.notVerified"
    case statusKnownLimitation = "apps.status.knownLimitation"
    case report = "apps.report"
    case details = "apps.details"
    case detailBundle = "apps.detail.bundle"
    case detailLastVerified = "apps.detail.lastVerified"
    case detailScopedTitle = "apps.detail.scoped.title"
    case scopeWebApp = "apps.scope.webApp"
    case scopeInApp = "apps.scope.inApp"
    case detailClose = "apps.detail.close"
    case compatTitle = "apps.compat.title"
    case compatExplanation = "apps.compat.explanation"
    case compatAutomatic = "apps.compat.automatic"
    case compatAutomaticExplanation = "apps.compat.automatic.explanation"
    case compatTypeSlower = "apps.compat.typeSlower"
    case compatTypeSlowerExplanation = "apps.compat.typeSlower.explanation"
    case compatSelectThenType = "apps.compat.selectThenType"
    case compatSelectThenTypeExplanation = "apps.compat.selectThenType.explanation"
    case compatPasteText = "apps.compat.pasteText"
    case compatPasteTextExplanation = "apps.compat.pasteText.explanation"
    case compatGuidedTest = "apps.compat.guidedTest"
    case compatGuidedTestExplanation = "apps.compat.guidedTest.explanation"
    case compatSetOn = "apps.compat.setOn"
    case pasteTitle = "apps.paste.title"
    case pasteBody = "apps.paste.body"
    case pasteConfirm = "apps.paste.confirm"
    case pasteCancel = "apps.paste.cancel"
}

/// Every interactive control that uses the `Apps` table, with its VoiceOver label and hint (PRD-R66).
public enum AppsControl: String, AccessibleControl {
    public static var table: StringTable { .apps }
    public static var keyPrefix: String { "apps" }

    case list
    case rowRule
    case rowDetails
    case rowReport
    case detailCompatibility
    /// The guided test's result in the compatibility radio group (`CompatibilityModeChoice.guidedTest`): not one
    /// of the PRD-R36 choices, so its row has its own label and a hint on how to remove it.
    case detailCompatibilityGuided
    case detailAdvanced
    case detailReport
    case detailClose
    case pasteConfirm
    case pasteCancel
    case resetPane
}
