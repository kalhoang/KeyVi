// SPDX-License-Identifier: LicenseRef-App-Pending
//
// About & Support pane logic (PRD-R24, PRD-R53, PRD-R59, ENG-R811): version line, update settings applied to the
// Sparkle wrapper, the "no downgrade" note when leaving Beta, licences and acknowledgements, donation block.

public import AppModel

public enum AboutSupportContent {
    /// "Phiên bản 0.1.0 (12)".
    public static func versionLine(brand: Brand, localizer: Localizer) -> String {
        localizer.format(SupportText.version, brand.version, brand.build)
    }

    /// PRD-R53: switching from Beta back to Stable offers the next stable when it is newer and never downgrades
    /// automatically, and the pane says so.
    public static func channelNote(from previous: UpdateChannel, to selected: UpdateChannel) -> SupportText? {
        previous == .beta && selected == .stable ? .channelNoDowngrade : nil
    }

    /// The Sparkle wrapper's view of the channel setting.
    public static func selection(for channel: UpdateChannel) -> UpdateChannelSelection {
        channel == .beta ? .beta : .stable
    }
}

/// Mirrors D19 to D21 onto the updater as soon as the user changes them (the wrapper also applies the stored
/// settings at launch, ADR 0304). Other edits are ignored.
public enum UpdaterSettingsBridge {
    @MainActor
    public static func apply(_ edit: SettingsEdit, to updater: any UpdaterControlling) {
        switch edit {
        case .automaticallyCheckForUpdates(let value): updater.automaticallyChecksForUpdates = value
        case .automaticallyInstallUpdates(let value): updater.automaticallyDownloadsUpdates = value
        case .updateChannel(let channel): updater.channel = AboutSupportContent.selection(for: channel)
        default: break
        }
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
    /// PRD-R59: the account name is shown in text next to the VietQR code.
    public func accountLine(_ localizer: Localizer) -> String {
        localizer.format(SupportText.donateAccountName, bankAccountName)
    }

    /// PRD-R57: GitHub Sponsors is shown only once Pa has a sponsor URL (VERIFY).
    public var showsSponsors: Bool { githubSponsorsURL != nil }
}
