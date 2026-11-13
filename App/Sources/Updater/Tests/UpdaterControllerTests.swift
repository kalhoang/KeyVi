// SPDX-License-Identifier: LicenseRef-App-Pending
//
// UpdaterController with a fake Sparkle driver (QA-R3): channels, settings D19-D21 at launch and on change,
// start-up refusals, logging, the idle relaunch and the update-failed alert. Delegate methods are called through
// `any SPUUpdaterDelegate`, so a witness that stopped matching Sparkle's selector fails here.

#if UPDATER_TESTS
import AppModel
import Diagnostics
import Foundation
import ShellCore
import Sparkle
import Testing

@MainActor
@Suite struct UpdaterChannelTests {
    @Test("PLT-R1101: stable allows only Sparkle's default channel")
    func stableAllowsNoExtraChannel() throws {
        let harness = UpdaterHarness()
        let updater = UpdaterFixtures.unstartedUpdater()
        #expect(harness.delegate.allowedChannels?(for: updater) == [])
        #expect(harness.controller.channel == .stable)
    }

    @Test("PLT-R1101, PRD-R53: beta only after opt-in, and leaving it removes the beta channel")
    func betaAfterOptIn() throws {
        let harness = UpdaterHarness()
        let updater = UpdaterFixtures.unstartedUpdater()
        harness.controller.channel = .beta
        #expect(harness.delegate.allowedChannels?(for: updater) == ["beta"])
        #expect(harness.changes == [.channel(.beta)])
        harness.controller.channel = .stable
        #expect(harness.delegate.allowedChannels?(for: updater) == [])
    }

    @Test("D21 from the settings store selects the channel")
    func channelFromSettings() throws {
        let harness = UpdaterHarness()
        harness.controller.apply(
            UpdatePreferences(automaticallyCheck: true, automaticallyInstall: true, channel: .beta))
        #expect(harness.delegate.allowedChannels?(for: UpdaterFixtures.unstartedUpdater()) == ["beta"])
        #expect(harness.changes.isEmpty, "applying stored settings is never reported back")
    }

    @Test("A channel change after start resets Sparkle's cycle; other changes do not")
    func channelChangeResetsCycle() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.controller.automaticallyChecksForUpdates = false
        #expect(harness.driver.resetCount == 0)
        harness.controller.channel = .beta
        #expect(harness.driver.resetCount == 1)
        harness.controller.channel = .beta
        #expect(harness.driver.resetCount == 1)
    }
}

@MainActor
@Suite struct UpdaterSettingsTests {
    @Test("D19-D21 applied before start reach Sparkle at start, with system profiling off (PRD-R55)")
    func appliedAtLaunch() throws {
        let harness = UpdaterHarness()
        harness.controller.apply(
            UpdatePreferences(automaticallyCheck: false, automaticallyInstall: false, channel: .stable))
        #expect(harness.factoryCalls == 0, "nothing touches Sparkle before start")
        harness.controller.start()
        #expect(harness.driver.startCount == 1)
        #expect(!harness.driver.automaticallyChecksForUpdates)
        #expect(!harness.driver.automaticallyDownloadsUpdates)
        #expect(!harness.driver.sendsSystemProfile)
        #expect(harness.controller.canCheckForUpdates)
    }

    @Test("Shipped defaults: daily check and background install on (PRD-R50), without rewriting equal values")
    func shippedDefaults() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        #expect(harness.controller.currentPreferences == UpdatePreferences.shipped)
        #expect(harness.controller.automaticallyChecksForUpdates)
        #expect(harness.controller.automaticallyDownloadsUpdates)
        #expect(harness.driver.checkWrites == 0 && harness.driver.downloadWrites == 0)
    }

    @Test("Settings changes after start are mirrored into Sparkle")
    func appliedOnChange() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.controller.apply(
            UpdatePreferences(automaticallyCheck: false, automaticallyInstall: true, channel: .stable))
        #expect(!harness.driver.automaticallyChecksForUpdates)
        harness.controller.apply(
            UpdatePreferences(automaticallyCheck: false, automaticallyInstall: false, channel: .stable))
        #expect(!harness.driver.automaticallyDownloadsUpdates)
        #expect(harness.changes.isEmpty)
    }

    @Test("User changes report only the changed key, once (PRD-R6)")
    func userChangesAreReported() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.controller.automaticallyChecksForUpdates = false
        harness.controller.automaticallyChecksForUpdates = false
        harness.controller.automaticallyDownloadsUpdates = false
        #expect(harness.changes == [.automaticallyCheck(false), .automaticallyInstall(false)])
        #expect(!harness.driver.automaticallyChecksForUpdates && !harness.driver.automaticallyDownloadsUpdates)
    }

    @Test("A choice made in Sparkle's update window is adopted at the end of the session")
    func adoptsSparkleWindowChoice() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.driver.simulateWindowCheckbox(automaticallyDownloads: false)
        harness.delegate.updater?(UpdaterFixtures.unstartedUpdater(), didFinishUpdateCycleFor: .updates, error: nil)
        #expect(!harness.controller.automaticallyDownloadsUpdates)
        #expect(harness.changes == [.automaticallyInstall(false)])
    }
}

@MainActor
@Suite struct UpdaterStartTests {
    @Test(
        "PLT-R1102: no EdDSA key, no Sparkle: refusal logged, checks disabled", arguments: ["", "$(KEY)", "c2hvcnQ="])
    func refusesWithoutKey(key: String) throws {
        let harness = UpdaterHarness(info: UpdaterFixtures.info(publicKey: key))
        harness.controller.start()
        #expect(harness.factoryCalls == 0)
        #expect(!harness.controller.canCheckForUpdates)
        #expect(harness.updateEvents == [.failed(code: UpdaterRefusal.publicKey.rawValue)])
        harness.controller.checkForUpdates()
        #expect(harness.driver.checkCount == 0)
    }

    @Test("PLT-R1102, PLT-R906: a feed that is not https on the site host is refused")
    func refusesForeignFeed() throws {
        let harness = UpdaterHarness(
            info: UpdaterFixtures.info(feedURL: "http://\(UpdaterFixtures.siteHost)/appcast.xml"))
        harness.controller.start()
        #expect(harness.factoryCalls == 0)
        #expect(harness.updateEvents == [.failed(code: UpdaterRefusal.feedURL.rawValue)])
    }

    @Test("A Sparkle start error is logged and leaves checks disabled")
    func sparkleStartError() throws {
        let harness = UpdaterHarness()
        harness.driver.startError = NSError(domain: "SUSparkleErrorDomain", code: 5)
        harness.controller.start()
        #expect(!harness.controller.canCheckForUpdates)
        #expect(harness.updateEvents == [.failed(code: 5)])
    }

    @Test("start runs once")
    func startIsIdempotent() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.controller.start()
        #expect(harness.factoryCalls == 1 && harness.driver.startCount == 1)
    }

    @Test("Check for updates is forwarded only while Sparkle allows it")
    func checkForUpdatesFollowsSparkle() throws {
        let harness = UpdaterHarness()
        harness.controller.checkForUpdates()
        #expect(harness.driver.checkCount == 0, "not started yet")
        harness.controller.start()
        harness.controller.checkForUpdates()
        #expect(harness.driver.checkCount == 1)
        harness.driver.canCheckForUpdates = false
        #expect(!harness.controller.canCheckForUpdates)
        harness.controller.checkForUpdates()
        #expect(harness.driver.checkCount == 1)
    }
}

@MainActor
@Suite struct UpdaterDelegateTests {
    /// The Objective-C selectors Sparkle 2.10.1 sends (SPUUpdaterDelegate.h). A Swift name that drifts from its
    /// selector would silently stop being called; this catches it.
    nonisolated static let delegateSelectors = [
        "allowedChannelsForUpdater:", "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
        "updater:mayPerformUpdateCheck:error:", "updater:didFindValidUpdate:", "updater:didAbortWithError:",
        "updater:userDidMakeChoice:forUpdate:state:", "updater:didFinishUpdateCycleForUpdateCheck:error:",
        "allowedSystemProfileKeysForUpdater:", "feedParametersForUpdater:sendingSystemProfile:",
    ]

    @Test("Every delegate selector Sparkle sends is implemented", arguments: delegateSelectors)
    func delegateSelectors(selector: String) throws {
        let harness = UpdaterHarness()
        #expect(harness.controller.responds(to: NSSelectorFromString(selector)))
    }

    @Test("Typed log events for checks, found updates and real failures only (PLT-R901)")
    func logsTypedEvents() throws {
        let harness = UpdaterHarness()
        let updater = UpdaterFixtures.unstartedUpdater()
        // Called on the controller: calling this optional throwing requirement through the existential crashes
        // the Swift 6.4.2 compiler in IRGen. `delegateSelectors` checks the selector instead.
        try harness.controller.updater(updater, mayPerform: .updates)
        try harness.controller.updater(updater, mayPerform: .updatesInBackground)
        harness.delegate.updater?(updater, didFindValidUpdate: SUAppcastItem.empty())
        for code in [1001, 4007, 4008, 2001] {
            harness.delegate.updater?(updater, didAbortWithError: NSError(domain: "SUSparkleErrorDomain", code: code))
        }
        #expect(
            harness.updateEvents == [
                .checkStarted(manual: true), .checkStarted(manual: false), .updateFound(build: ""),
                .failed(code: 2001),
            ])
    }

    @Test("PRD-R55, PLT-R906: no system profile keys and no extra feed parameters")
    func noSystemProfile() throws {
        let harness = UpdaterHarness()
        let updater = UpdaterFixtures.unstartedUpdater()
        #expect(harness.delegate.allowedSystemProfileKeys?(for: updater) == [])
        let parameters = harness.delegate.feedParameters?(for: updater, sendingSystemProfile: true)
        #expect(parameters?.isEmpty == true)
    }

    @Test("PLT-R1105: install on quit is taken over and runs only after 60 s idle with secure input off")
    func installOnQuitWaitsForIdle() throws {
        let harness = UpdaterHarness()
        var installs = 0
        harness.idle.pressKey()
        let tookOver = harness.delegate.updater?(
            UpdaterFixtures.unstartedUpdater(), willInstallUpdateOnQuit: SUAppcastItem.empty(),
            immediateInstallationBlock: { installs += 1 })
        #expect(tookOver == true)
        #expect(harness.updateEvents == [.installScheduledOnQuit])
        harness.advance(seconds: 59)
        #expect(installs == 0)
        harness.advance(seconds: 1)
        #expect(installs == 1)
        harness.advance(seconds: 600)
        #expect(installs == 1)
    }

    @Test("PLT-R1105: turning automatic installation off cancels a pending automatic relaunch")
    func disablingAutomaticInstallCancelsRelaunch() throws {
        let harness = UpdaterHarness()
        var installs = 0
        harness.idle.pressKey()
        _ = harness.delegate.updater?(
            UpdaterFixtures.unstartedUpdater(), willInstallUpdateOnQuit: SUAppcastItem.empty(),
            immediateInstallationBlock: { installs += 1 })
        harness.controller.automaticallyDownloadsUpdates = false
        harness.advance(seconds: 600)
        #expect(installs == 0)
        #expect(harness.scheduler.pendingCount == 0)
    }
}

@MainActor
@Suite struct UpdaterFailureTests {
    func failSession(_ harness: UpdaterHarness) throws -> Int {
        harness.controller.start()
        let report = try #require(harness.reportError)
        var acknowledgements = 0
        report(NSError(domain: "SUSparkleErrorDomain", code: 2001)) { acknowledgements += 1 }
        return acknowledgements
    }

    @Test("PRD-R43: Sparkle's error is shown with our copy in the interface language, then acknowledged")
    func showsLocalizedFailure() throws {
        let harness = UpdaterHarness(language: .english)
        #expect(try failSession(harness) == 1)
        let content = try #require(harness.presenter.presented.first)
        #expect(content.title == "The update could not be downloaded.")
        #expect(content.message.contains(UpdaterFixtures.version))
        #expect(content.buttons.map(\.control) == [.retry, .download, .close])
    }

    @Test("PRD-R43 \"Thử lại\": a new check after the failed session ended")
    func retryChecksAgain() throws {
        let harness = UpdaterHarness()
        harness.presenter.choice = .retry
        _ = try failSession(harness)
        #expect(harness.driver.checkCount == 0)
        harness.advance(seconds: 1)
        #expect(harness.driver.checkCount == 1)
        #expect(harness.openedURLs.isEmpty)
    }

    @Test("PRD-R43 \"Tải từ trang web\": opens the download page on the site host")
    func downloadOpensSite() throws {
        let harness = UpdaterHarness()
        harness.presenter.choice = .download
        _ = try failSession(harness)
        #expect(harness.openedURLs == [URL(string: "https://\(UpdaterFixtures.siteHost)/tai-ve/")!])
        harness.advance(seconds: 5)
        #expect(harness.driver.checkCount == 0)
    }

    @Test("Close does nothing else")
    func closeDoesNothing() throws {
        let harness = UpdaterHarness()
        _ = try failSession(harness)
        harness.advance(seconds: 5)
        #expect(harness.driver.checkCount == 0 && harness.openedURLs.isEmpty)
    }
}
#endif
