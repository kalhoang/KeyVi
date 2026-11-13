// SPDX-License-Identifier: GPL-3.0-or-later
//
// About & Support pane logic (PRD-R24, PRD-R53, PRD-R59, ENG-R811): version line, update settings applied to the
// Sparkle wrapper, licences and acknowledgements, donation block (a bank VietQR code only, Pa's decision S8). The
// "no downgrade" note when leaving Beta is the updater's `UpdateChannelNote` (App/Sources/Updater, `Updates`
// table).

public import AppModel

public enum AboutSupportContent {
    /// "Phiên bản 0.1.0 (12)".
    public static func versionLine(brand: Brand, localizer: Localizer) -> String {
        localizer.format(SupportText.version, brand.version, brand.build)
    }

    /// The Sparkle wrapper's view of the channel setting.
    public static func selection(for channel: UpdateChannel) -> UpdateChannelSelection {
        channel == .beta ? .beta : .stable
    }
}

/// Licences and acknowledgements: the bundled data's notices (ENG-R811, SCOWL) from
/// `VietnameseEngineData.Resources.bundledNotices()`, then Sparkle's licence.
public struct Acknowledgements: Sendable, Hashable {
    public struct Section: Sendable, Hashable, Identifiable {
        public var id: SupportText { title }
        public var title: SupportText
        public var text: String
    }

    public let sections: [Section]

    /// `dataNotices` is `Resources.bundledNotices` in the app; a failure shows a plain line instead of the text.
    public init(dataNotices: () throws -> String, localizer: Localizer) {
        let data = (try? dataNotices()) ?? localizer.string(SupportText.licencesUnavailable)
        sections = [
            Section(title: .licencesData, text: data),
            Section(title: .licencesSparkle, text: SparkleNotice.text),
        ]
    }
}

extension DonationInfo {
    /// PRD-R59, S8: "Ngân hàng: LioBank" next to the VietQR code.
    public func bankLine(_ localizer: Localizer) -> String {
        localizer.format(SupportText.donateBank, bankName)
    }

    /// PRD-R59, S8: "Số tài khoản: 688688678"; the holder's name is never shown.
    public func accountNumberLine(_ localizer: Localizer) -> String {
        localizer.format(SupportText.donateAccountNumber, accountNumber)
    }

    /// PRD-R57: GitHub Sponsors is shown only once Pa has a sponsor URL (VERIFY).
    public var showsSponsors: Bool { githubSponsorsURL != nil }
}
