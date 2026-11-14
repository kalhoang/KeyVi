// SPDX-License-Identifier: GPL-3.0-or-later
//
// About, Support and Licences pane logic (PRD-R24, PRD-R53, PRD-R59, ENG-R811; Pa, 15/11/2026): version line, update
// settings applied to the Sparkle wrapper, the donation block (a bank VietQR code only, Pa's decision S8) with its
// share text, the licences and acknowledgements. The "no downgrade" note when leaving Beta is the updater's
// `UpdateChannelNote` (App/Sources/Updater, `Updates` table).

public import AppModel
public import Foundation

public enum AboutSupportContent {
    /// "Phiên bản 0.1.0 (12)".
    public static func versionLine(brand: Brand, localizer: Localizer) -> String {
        localizer.format(SupportText.version, brand.version, brand.build)
    }

    /// The Sparkle wrapper's view of the channel setting.
    public static func selection(for channel: UpdateChannel) -> UpdateChannelSelection {
        channel == .beta ? .beta : .stable
    }

    /// The donation block's "Nội dung chia sẻ" (Pa's wording, 15/11/2026): the marked name and the website's address
    /// as Pa wrote it, `https://<site host>`, nothing about the user (PRD-R59). The address is the same in both
    /// languages: the people the user shares it with pick their own language on the site.
    public static func shareText(brand: Brand, localizer: Localizer) -> String {
        localizer.format(SupportText.donateShareText, brand.markedName, "https://\(brand.siteHost)")
    }

    /// "Bản quyền © 2026 các tác giả <name>", the line of the LICENSE files.
    public static func copyrightLine(brand: Brand, localizer: Localizer) -> String {
        localizer.format(SupportText.licencesCopyright, brand.displayName)
    }

    /// The Support pane's mail link; nil hides the email row (no APP_SUPPORT_EMAIL).
    public static func mailURL(brand: Brand) -> URL? {
        brand.supportEmail.flatMap { URL(string: "mailto:\($0)") }
    }
}

/// Licences and acknowledgements of the Licences pane: the MPL-2.0 licence of the Vietnamese engine
/// (`EngineLicence`, the app ships it), the bundled data's notices (ENG-R811, SCOWL) from
/// `VietnameseEngineData.Resources.bundledNotices()`, then Sparkle's licence. The app's own GPL-3.0-or-later text is
/// the bundle's LICENSE file (ADR 0006).
public struct Acknowledgements: Sendable, Hashable {
    public struct Section: Sendable, Hashable, Identifiable {
        public var id: SupportText { title }
        public var title: SupportText
        public var text: String
    }

    public let sections: [Section]

    /// `dataNotices` is `Resources.bundledNotices` in the app; a failure shows a plain line instead of the text.
    public init(dataNotices: () throws -> String, appName: String, localizer: Localizer) {
        let data = (try? dataNotices()) ?? localizer.string(SupportText.licencesUnavailable)
        sections = [
            Section(title: .licencesEngine, text: EngineLicence.text(appName: appName)),
            Section(title: .licencesData, text: data),
            Section(title: .licencesSparkle, text: SparkleNotice.text),
        ]
    }
}

/// One line of the donation block's "Thông tin tài khoản": its label, the value the user can select and copy, and
/// the copy button's control (PRD-R66).
public struct DonationDetail: Sendable, Hashable, Identifiable {
    public var id: SupportText { label }
    public var label: SupportText
    public var value: String
    public var copyControl: SupportControl
}

extension DonationInfo {
    /// PRD-R59, S8: the bank and the account number; the holder's name is never shown.
    public var details: [DonationDetail] {
        [
            DonationDetail(label: .donateBankLabel, value: bankName, copyControl: .copyBank),
            DonationDetail(label: .donateAccountLabel, value: accountNumber, copyControl: .copyAccount),
        ]
    }

    /// PRD-R57: GitHub Sponsors is shown only once Pa has a sponsor URL (VERIFY).
    public var showsSponsors: Bool { githubSponsorsURL != nil }
}
