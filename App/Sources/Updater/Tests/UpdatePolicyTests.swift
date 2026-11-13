// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Sparkle-free rules: D19-D21 mapping, explicit-key writes, channel mapping and notice, failure filter and the
// start-up configuration check (PLT-R1101, PLT-R1102, PRD-R6, PRD-R53, PRD-R55).

#if UPDATER_TESTS
import AppModel
import Foundation
import SettingsStore
import ShellCore
import Testing

@Suite struct UpdatePreferencesTests {
    @Test("Shipped defaults: D19 on, D20 on, D21 stable")
    func shippedDefaults() {
        #expect(
            UpdatePreferences.shipped
                == UpdatePreferences(automaticallyCheck: true, automaticallyInstall: true, channel: .stable))
    }

    @Test("Effective settings map onto the three preferences")
    func fromEffectiveSettings() {
        var settings = DefaultSettings.v1
        settings.automaticallyCheckForUpdates = false
        settings.automaticallyInstallUpdates = false
        settings.updateChannel = .beta
        #expect(
            UpdatePreferences(settings)
                == UpdatePreferences(automaticallyCheck: false, automaticallyInstall: false, channel: .beta))
    }

    @Test(
        "PRD-R6: a change writes only its own key, as an explicit value",
        arguments: [
            UpdatePreferenceChange.automaticallyCheck(false), .automaticallyInstall(false), .channel(.beta),
        ])
    func changeWritesOneKey(change: UpdatePreferenceChange) {
        var user = UserSettings()
        change.apply(to: &user)
        let explicit = [
            user.automaticallyCheckForUpdates.isSet, user.automaticallyInstallUpdates.isSet, user.updateChannel.isSet,
        ]
        #expect(explicit.filter { $0 }.count == 1)
        let effective = UpdatePreferences(user.resolved())
        #expect(effective == UpdatePreferences.shipped.applying(change))
    }
}

@Suite struct UpdateChannelPolicyTests {
    @Test("QA-R28: beta users keep the default channel, so newer stable releases still reach them")
    func allowedChannels() {
        #expect(UpdateChannelPolicy.allowedChannels(for: .stable).isEmpty)
        #expect(UpdateChannelPolicy.allowedChannels(for: .beta) == ["beta"])
    }

    @Test("Selection and stored channel map both ways", arguments: UpdateChannel.allCases)
    func roundTrip(channel: UpdateChannel) {
        let selection = UpdateChannelPolicy.selection(for: channel)
        #expect(selection.rawValue == channel.rawValue)
        #expect(UpdateChannelPolicy.channel(for: selection) == channel)
    }

    @Test("PRD-R53: only leaving Beta shows the no-downgrade note")
    func noDowngradeNotice() {
        #expect(UpdateChannelPolicy.notice(switchingFrom: .beta, to: .stable) == .stableNoDowngrade)
        #expect(UpdateChannelPolicy.notice(switchingFrom: .stable, to: .beta) == nil)
        #expect(UpdateChannelPolicy.notice(switchingFrom: .stable, to: .stable) == nil)
        #expect(UpdateChannelPolicy.notice(switchingFrom: .beta, to: .beta) == nil)
    }

    @Test("PRD-R53: the About & Support note follows each channel change and names the app")
    func channelNoteOfTheSettingsPane() throws {
        var note = UpdateChannelNote()
        let vi = TestResources.localizer(.vietnamese)
        #expect(note.text(appName: UpdaterFixtures.appName, localizer: vi) == nil)
        note.channelChanged(from: .beta, to: .stable)
        #expect(note.key == .stableNoDowngrade)
        let table = try TestResources.updatesTable(.vietnamese)
        let template = try #require(table[UpdatesText.stableNoDowngrade.rawValue])
        let expected = template.replacingOccurrences(of: "%@", with: UpdaterFixtures.appName)
        #expect(note.text(appName: UpdaterFixtures.appName, localizer: vi) == expected)
        note.channelChanged(from: .stable, to: .beta)
        #expect(note.key == nil, "a later change clears the note")
    }
}

@Suite struct UpdateFailureFilterTests {
    @Test("No update, cancelled and authorise-later are normal endings", arguments: [1001, 4007, 4008])
    func normalEndings(code: Int) { #expect(!UpdateFailureFilter.isFailure(code: code)) }

    @Test("Download, signature and installation errors are failures", arguments: [1002, 2001, 3001, 4005])
    func failures(code: Int) { #expect(UpdateFailureFilter.isFailure(code: code)) }
}

@Suite struct UpdaterConfigurationTests {
    @Test("The fixture configuration may start")
    func validConfiguration() {
        #expect(UpdaterConfiguration.refusal(info: UpdaterFixtures.info()) == nil)
    }

    @Test("The feed URL is https://<site host>/appcast.xml")
    func expectedFeedURL() {
        #expect(
            UpdaterConfiguration.expectedFeedURL(siteHost: "example.org")
                == URL(string: "https://example.org/appcast.xml"))
    }

    @Test(
        "PLT-R1101, PLT-R1102: only the https appcast on the site host is accepted",
        arguments: [
            nil, "", "http://updates.example.test/appcast.xml", "https://elsewhere.example.test/appcast.xml",
            "https://updates.example.test/feed.xml", "$(SPARKLE_FEED_URL)",
        ] as [String?])
    func refusesFeed(feed: String?) {
        #expect(UpdaterConfiguration.refusal(info: UpdaterFixtures.info(feedURL: feed)) == .feedURL)
    }

    @Test("A missing site host is a feed refusal")
    func missingSiteHost() {
        var info = UpdaterFixtures.info()
        info[Brand.InfoKey.siteHost] = ""
        #expect(UpdaterConfiguration.refusal(info: info) == .feedURL)
    }

    @Test(
        "PLT-R1102, QA-R33: the EdDSA key must be a 32-byte ed25519 key",
        arguments: [nil, "", "$(SPARKLE_PUBLIC_ED_KEY)", "not base64!", Data(count: 16).base64EncodedString()]
            as [String?])
    func refusesKey(key: String?) {
        #expect(UpdaterConfiguration.refusal(info: UpdaterFixtures.info(publicKey: key)) == .publicKey)
    }

    @Test("PRD-R55: system profiling turned on is refused")
    func refusesProfiling() {
        #expect(UpdaterConfiguration.refusal(info: UpdaterFixtures.info(systemProfiling: true)) == .systemProfiling)
    }

    @Test("Refusal codes are negative, apart from Sparkle's positive error codes")
    func refusalCodesAreNegative() {
        #expect(UpdaterRefusal.allCases.allSatisfy { $0.rawValue < 0 })
        #expect(Set(UpdaterRefusal.allCases.map(\.rawValue)).count == UpdaterRefusal.allCases.count)
    }
}
#endif
