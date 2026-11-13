// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Sparkle-free rules of the updater (PLT-R1101, PLT-R1102, PLT-R1105, PRD-R50, PRD-R53, PRD-R55). Kept apart from
// the Sparkle adapter so every rule is unit tested without an `SPUUpdater`.

import AppModel
import Foundation
import SettingsStore
import ShellCore

/// Settings D19-D21 as the updater applies them to Sparkle.
struct UpdatePreferences: Sendable, Hashable {
    /// D19, `SPUUpdater.automaticallyChecksForUpdates` (daily check, PLT-R1105).
    var automaticallyCheck: Bool
    /// D20, `SPUUpdater.automaticallyDownloadsUpdates` (background download, install on quit, PRD-R50).
    var automaticallyInstall: Bool
    /// D21, the channels returned from `allowedChannels(for:)` (PLT-R1101).
    var channel: UpdateChannel

    init(automaticallyCheck: Bool, automaticallyInstall: Bool, channel: UpdateChannel) {
        self.automaticallyCheck = automaticallyCheck
        self.automaticallyInstall = automaticallyInstall
        self.channel = channel
    }

    init(_ settings: EffectiveSettings) {
        self.init(
            automaticallyCheck: settings.automaticallyCheckForUpdates,
            automaticallyInstall: settings.automaticallyInstallUpdates, channel: settings.updateChannel)
    }

    /// The shipped defaults, used until the composition root applies the loaded settings.
    static let shipped = UpdatePreferences(DefaultSettings.v1)

    func applying(_ change: UpdatePreferenceChange) -> UpdatePreferences {
        var next = self
        switch change {
        case .automaticallyCheck(let value): next.automaticallyCheck = value
        case .automaticallyInstall(let value): next.automaticallyInstall = value
        case .channel(let value): next.channel = value
        }
        return next
    }
}

/// One user change of D19, D20 or D21, from the About & Support pane or from Sparkle's own update window.
enum UpdatePreferenceChange: Sendable, Hashable {
    case automaticallyCheck(Bool)
    case automaticallyInstall(Bool)
    case channel(UpdateChannel)

    /// Writes only the changed key, as an explicit value, so the other keys keep following the defaults (PRD-R6).
    func apply(to settings: inout UserSettings) {
        switch self {
        case .automaticallyCheck(let value): settings.automaticallyCheckForUpdates = .set(value)
        case .automaticallyInstall(let value): settings.automaticallyInstallUpdates = .set(value)
        case .channel(let value): settings.updateChannel = .set(value)
        }
    }
}

/// Channel rules (PLT-R1101, PRD-R53, QA-R28).
enum UpdateChannelPolicy {
    /// `sparkle:channel` of beta items in the single appcast (spec/03-product.md section 14, `/appcast.xml`).
    static let betaChannelName = "beta"

    /// Sparkle always includes the default channel, so stable users get `[]` and beta users get `["beta"]`: beta
    /// users still receive stable releases newer than the latest beta (QA-R28).
    static func allowedChannels(for channel: UpdateChannel) -> Set<String> {
        switch channel {
        case .stable: []
        case .beta: [betaChannelName]
        }
    }

    static func selection(for channel: UpdateChannel) -> UpdateChannelSelection {
        switch channel {
        case .stable: .stable
        case .beta: .beta
        }
    }

    static func channel(for selection: UpdateChannelSelection) -> UpdateChannel {
        switch selection {
        case .stable: .stable
        case .beta: .beta
        }
    }

    /// PRD-R53: leaving Beta never downgrades (Sparkle only offers newer builds), and the pane says so.
    /// Consumer: the About & Support pane (W2-B, App/Sources/Settings) calls this after a channel change and shows
    /// `localizer.format(key, appName)` as a one-line note. Not dead code while that pane is being built.
    static func notice(switchingFrom old: UpdateChannelSelection, to new: UpdateChannelSelection) -> UpdatesText? {
        old == .beta && new == .stable ? .stableNoDowngrade : nil
    }
}

/// Which Sparkle aborts are failures worth logging (codes from Sparkle's `SUErrors.h`).
enum UpdateFailureFilter {
    /// `SUNoUpdateError` (1001), `SUInstallationCanceledError` (4007) and `SUInstallationAuthorizeLaterError` (4008)
    /// are normal endings of a session, not failures.
    static let normalEndings: Set<Int> = [1001, 4007, 4008]

    static func isFailure(code: Int) -> Bool { !normalEndings.contains(code) }
}

/// Why the updater refused to start Sparkle. Negative codes keep them apart from Sparkle's positive error codes
/// in `LogEvent.UpdateEvent.failed(code:)`.
enum UpdaterRefusal: Int, Sendable, Hashable, Error, CaseIterable {
    /// `SUFeedURL` is not `https://<site host>/appcast.xml` (PLT-R1101, PLT-R1102, PLT-R906).
    case feedURL = -1
    /// `SUPublicEDKey` is empty or not a 32-byte ed25519 key: EdDSA is mandatory (PLT-R1102, QA-R33).
    case publicKey = -2
    /// `SUEnableSystemProfiling` is on (PRD-R55).
    case systemProfiling = -3
}

/// Start-up check of the Sparkle keys in the app's Info.plist. A Debug build without the EdDSA key (the key is
/// filled by Pa, ADR 0304 runbook note) therefore never contacts the appcast.
enum UpdaterConfiguration {
    enum InfoKey {
        static let feedURL = "SUFeedURL"
        static let publicEDKey = "SUPublicEDKey"
        static let systemProfiling = "SUEnableSystemProfiling"
    }

    static let ed25519PublicKeyLength = 32

    /// `https://<site host>/appcast.xml`: one stable URL that never moves (spec/03-product.md section 14).
    static func expectedFeedURL(siteHost: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/appcast.xml"
        return components.url
    }

    /// nil when Sparkle may start; otherwise the first problem found.
    static func refusal(info: [String: Any]) -> UpdaterRefusal? {
        guard let siteHost = info[Brand.InfoKey.siteHost] as? String, !siteHost.isEmpty,
            let feed = info[InfoKey.feedURL] as? String, let expected = expectedFeedURL(siteHost: siteHost),
            URL(string: feed) == expected
        else { return .feedURL }
        guard isEd25519PublicKey(info[InfoKey.publicEDKey] as? String) else { return .publicKey }
        if (info[InfoKey.systemProfiling] as? Bool) == true { return .systemProfiling }
        return nil
    }

    static func isEd25519PublicKey(_ value: String?) -> Bool {
        guard let value, let data = Data(base64Encoded: value) else { return false }
        return data.count == ed25519PublicKeyLength
    }
}
