// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed keys of the `Support` String Catalog (ADR 0310, PRD-R62, PRD-R66): the About, Support and Licences panes
// and the donation block (PRD-R24, PRD-R53, PRD-R59; Pa, 15/11/2026). A catalog test checks that every key exists in vi and en with matching
// arguments and that the catalog holds no dead copy.

/// `Support` table keys.
public enum SupportText: String, LocalizationKey {
    public static var table: StringTable { .support }

    case version = "support.version"
    /// About: one line under the name.
    case aboutDescription = "support.about.description"
    case updatesTitle = "support.updates.title"
    case channelTitle = "support.channel.title"
    case channelExplanation = "support.channel.explanation"
    case channelStable = "support.channel.stable"
    case channelBeta = "support.channel.beta"
    case autoCheckTitle = "support.autoCheck.title"
    case autoCheckExplanation = "support.autoCheck.explanation"
    case autoInstallTitle = "support.autoInstall.title"
    case autoInstallExplanation = "support.autoInstall.explanation"
    case checkNow = "support.checkNow"
    case reopenOnboarding = "support.reopenOnboarding"
    // Support: diagnostics and report, help on the website and by email, settings transfer, privacy.
    case reportTitle = "support.report.title"
    case reportProblem = "support.reportProblem"
    case diagnostics = "support.diagnostics"
    case diagnosticsExplanation = "support.diagnostics.explanation"
    case helpTitle = "support.help.title"
    case helpWebsiteTitle = "support.help.website.title"
    case helpWebsiteExplanation = "support.help.website.explanation"
    case helpWebsiteOpen = "support.help.website.open"
    case helpEmailTitle = "support.help.email.title"
    /// Argument: the support address (Config/Brand.xcconfig APP_SUPPORT_EMAIL).
    case helpEmailExplanation = "support.help.email.explanation"
    case helpEmailOpen = "support.help.email.open"
    case settingsTitle = "support.settings.title"
    /// Under the export, import and reset buttons (W8-D grouped section).
    case settingsExplanation = "support.settings.explanation"
    case exportSettings = "support.exportSettings"
    case importSettings = "support.importSettings"
    case resetAll = "support.resetAll"
    case privacyTitle = "support.privacy.title"
    /// Argument: the name with its trademark sign (`Brand.markedName`).
    case privacyBody = "support.privacy.body"
    // Licences: copyright, the app's GPL-3.0-or-later licence (ADR 0006), the MPL-2.0 engine, notices and credits.
    /// Argument: the display name, as in the LICENSE files ("the <name> authors").
    case licencesCopyright = "support.licences.copyright"
    /// Argument: the name with its trademark sign.
    case licencesSummary = "support.licences.summary"
    case licencesSource = "support.licences.source"
    case licencesSectionLicences = "support.licences.section.licences"
    case licencesSectionCredits = "support.licences.section.credits"
    /// ADR 0006: "<app name>: GPL-3.0-or-later", the app's own licence row.
    case licencesApp = "support.licences.app"
    case licencesEngine = "support.licences.engine"
    case licencesData = "support.licences.data"
    case licencesSparkle = "support.licences.sparkle"
    case licencesUnavailable = "support.licences.unavailable"
    // Donation block (PRD-R59, Pa's copy of 15/11/2026).
    /// Argument: the name with its trademark sign.
    case donateTitle = "support.donate.title"
    /// Argument: the name with its trademark sign.
    case donateBody = "support.donate.body"
    /// Argument: the display name.
    case donateHowTo = "support.donate.howTo"
    case donateAccountTitle = "support.donate.accountTitle"
    case donateBankLabel = "support.donate.bankLabel"
    case donateAccountLabel = "support.donate.accountLabel"
    case donateCopy = "support.donate.copy"
    case donateCopied = "support.donate.copied"
    case donateShareTitle = "support.donate.shareTitle"
    /// Pa's wording (15/11/2026). Arguments: the name with its trademark sign, then `https://<site host>`.
    case donateShareText = "support.donate.shareText"
    case donateShare = "support.donate.share"
    case donateVietQR = "support.donate.vietQR"
    case donateScanHint = "support.donate.scanHint"
    case donateSponsors = "support.donate.sponsors"
    case donateVietQRImage = "support.donate.vietQR.image"
}

/// Every interactive control that uses the `Support` table, with its VoiceOver label and hint (PRD-R66).
public enum SupportControl: String, AccessibleControl {
    public static var table: StringTable { .support }
    public static var keyPrefix: String { "support" }

    case channel
    case autoCheck
    case autoInstall
    case checkNow
    case reopenOnboarding
    case reportProblem
    case diagnostics
    case helpWebsite
    case helpEmail
    case exportSettings
    case importSettings
    case resetAll
    case sourceLink
    case appLicence
    case notice
    case copyBank
    case copyAccount
    case copyShareText
    case share
    case sponsorsLink
}
