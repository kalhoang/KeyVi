// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed keys of the `Support` String Catalog (ADR 0310, PRD-R62, PRD-R66): About & Support pane, licences and the
// donation block (PRD-R24, PRD-R53, PRD-R59). A catalog test checks that every key exists in vi and en with matching
// arguments and that the catalog holds no dead copy.

/// `Support` table keys.
public enum SupportText: String, LocalizationKey {
    public static var table: StringTable { .support }

    case version = "support.version"
    case updatesTitle = "support.updates.title"
    case channelTitle = "support.channel.title"
    case channelExplanation = "support.channel.explanation"
    case channelStable = "support.channel.stable"
    case channelBeta = "support.channel.beta"
    case channelNoDowngrade = "support.channel.noDowngrade"
    case autoCheckTitle = "support.autoCheck.title"
    case autoCheckExplanation = "support.autoCheck.explanation"
    case autoInstallTitle = "support.autoInstall.title"
    case autoInstallExplanation = "support.autoInstall.explanation"
    case checkNow = "support.checkNow"
    case helpTitle = "support.help.title"
    case reportProblem = "support.reportProblem"
    case diagnostics = "support.diagnostics"
    case diagnosticsExplanation = "support.diagnostics.explanation"
    case reopenOnboarding = "support.reopenOnboarding"
    case settingsTitle = "support.settings.title"
    case exportSettings = "support.exportSettings"
    case importSettings = "support.importSettings"
    case resetAll = "support.resetAll"
    case privacyTitle = "support.privacy.title"
    case privacyBody = "support.privacy.body"
    case licences = "support.licences"
    case licencesTitle = "support.licences.title"
    case licencesData = "support.licences.data"
    case licencesSparkle = "support.licences.sparkle"
    case licencesUnavailable = "support.licences.unavailable"
    case licencesClose = "support.licences.close"
    case donateTitle = "support.donate.title"
    case donateBody = "support.donate.body"
    case donateVietQR = "support.donate.vietQR"
    case donateMoMo = "support.donate.momo"
    case donateAccountName = "support.donate.accountName"
    case donateSponsors = "support.donate.sponsors"
    case donateVietQRImage = "support.donate.vietQR.image"
    case donateMoMoImage = "support.donate.momo.image"
}

/// Every interactive control that uses the `Support` table, with its VoiceOver label and hint (PRD-R66).
public enum SupportControl: String, AccessibleControl {
    public static var table: StringTable { .support }
    public static var keyPrefix: String { "support" }

    case channel
    case autoCheck
    case autoInstall
    case checkNow
    case reportProblem
    case diagnostics
    case reopenOnboarding
    case exportSettings
    case importSettings
    case resetAll
    case licences
    case licencesClose
    case sponsorsLink
}
