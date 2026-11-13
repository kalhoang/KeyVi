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
        harness.delegate.updater?(UpdaterFixtures.unstartedUpdater(), didFinishUpdateCycleFor: .updates, error: nil)
        #expect(harness.changes == [.automaticallyInstall(false)], "an adopted choice is reported once")
    }

    @Test("PRD-R6: a value Sparkle ignored is never adopted as a user choice, cycle after cycle")
    func ignoredSparkleWriteIsNotAdopted() throws {
        let harness = UpdaterHarness()
        harness.driver.disallowAutomaticUpdates()
        harness.controller.start()
        #expect(harness.driver.downloadWrites == 1, "the shipped D20 was pushed and Sparkle ignored it")
        for _ in 0..<3 {
            harness.delegate.updater?(
                UpdaterFixtures.unstartedUpdater(), didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        }
        #expect(harness.changes.isEmpty)
        #expect(harness.controller.automaticallyDownloadsUpdates)
    }

    @Test("A choice made in Sparkle's update window is adopted when the user answers it")
    func adoptsChoiceOnUserAnswer() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.driver.automaticallyChecksForUpdates = false
        harness.delegate.updater?(
            UpdaterFixtures.unstartedUpdater(), userDidMake: .dismiss, forUpdate: SUAppcastItem.empty(),
            state: try UpdaterFixtures.userUpdateState())
        #expect(harness.changes == [.automaticallyCheck(false)])
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

    /// Offers Sparkle's immediate install to the delegate; returns whether it took over and how often it installed.
    func offerInstall(_ harness: UpdaterHarness) -> (tookOver: Bool?, installs: Int) {
        var installs = 0
        let tookOver = harness.delegate.updater?(
            UpdaterFixtures.unstartedUpdater(), willInstallUpdateOnQuit: SUAppcastItem.empty(),
            immediateInstallationBlock: { installs += 1 })
        return (tookOver, installs)
    }

    @Test("PLT-R1105: idle for 60 s with secure input off: the update installs and relaunches at once")
    func idleKeyboardInstallsNow() throws {
        let harness = UpdaterHarness()
        harness.idle.pressKey()
        harness.advance(seconds: 60)
        let offer = offerInstall(harness)
        #expect(offer.tookOver == true)
        #expect(offer.installs == 1)
        #expect(harness.updateEvents == [.installingNow], "the log shows which path ran")
    }

    @Test("PLT-R1105: no key since launch counts as idle")
    func noKeySinceLaunchInstallsNow() throws {
        let offer = offerInstall(UpdaterHarness())
        #expect(offer.tookOver == true && offer.installs == 1)
    }

    @Test("PLT-R1105: a key pressed within 60 s leaves the update to Sparkle, which installs it at quit")
    func recentKeyInstallsAtQuit() throws {
        let harness = UpdaterHarness()
        harness.idle.pressKey()
        harness.advance(seconds: 59)
        let offer = offerInstall(harness)
        #expect(offer.tookOver == false, "returning true would stall Sparkle's update cycle")
        #expect(offer.installs == 0)
        #expect(harness.updateEvents == [.installScheduledOnQuit])
    }

    @Test("PLT-R1105: secure input on leaves the update to Sparkle, however long the keyboard was idle")
    func secureInputInstallsAtQuit() throws {
        let harness = UpdaterHarness()
        harness.idle.secureInputOn = true
        let offer = offerInstall(harness)
        #expect(offer.tookOver == false && offer.installs == 0)
    }

    @Test("PLT-R1105, PRD-R54: while the update waits for quit, checks stay available and nothing is pending")
    func updaterStaysUsableWhileWaitingForQuit() throws {
        let harness = UpdaterHarness()
        harness.controller.start()
        harness.idle.secureInputOn = true
        _ = offerInstall(harness)
        #expect(harness.controller.canCheckForUpdates)
        harness.controller.checkForUpdates()
        #expect(harness.driver.checkCount == 1)
        #expect(harness.mainTurns.isEmpty)
    }
}

@MainActor
@Suite struct UpdaterFailureTests {
    /// Reports a Sparkle error and runs the next main-queue turn; returns the acknowledgements seen when the alert
    /// appeared.
    func failSession(_ harness: UpdaterHarness) throws -> Int? {
        harness.controller.start()
        let report = try #require(harness.reportError)
        var acknowledgements = 0
        var acknowledgementsAtPresent: Int?
        harness.presenter.onPresent = { acknowledgementsAtPresent = acknowledgements }
        report(NSError(domain: "SUSparkleErrorDomain", code: 2001)) { acknowledgements += 1 }
        #expect(acknowledgements == 1, "Sparkle's session is acknowledged at once")
        #expect(harness.presenter.presented.isEmpty, "the alert waits for the next main-queue turn")
        harness.runMainTurn()
        #expect(acknowledgements == 1)
        return acknowledgementsAtPresent
    }

    @Test("PRD-R43: Sparkle's session is acknowledged before the alert, so its progress window is closed first")
    func acknowledgesBeforePresenting() throws {
        let harness = UpdaterHarness()
        #expect(try failSession(harness) == 1)
        #expect(harness.presenter.presented.count == 1)
    }

    @Test("PRD-R43: Sparkle's error is shown with our copy in the interface language")
    func showsLocalizedFailure() throws {
        let harness = UpdaterHarness(language: .english)
        _ = try failSession(harness)
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
        #expect(harness.driver.checkCount == 1)
        #expect(harness.openedURLs.isEmpty)
    }

    @Test("PRD-R43 \"Tải từ trang web\": opens the download page on the site host")
    func downloadOpensSite() throws {
        let harness = UpdaterHarness()
        harness.presenter.choice = .download
        _ = try failSession(harness)
        #expect(harness.openedURLs == [URL(string: "https://\(UpdaterFixtures.siteHost)/tai-ve/")!])
        #expect(harness.driver.checkCount == 0)
    }

    @Test("Close does nothing else")
    func closeDoesNothing() throws {
        let harness = UpdaterHarness()
        _ = try failSession(harness)
        #expect(harness.driver.checkCount == 0 && harness.openedURLs.isEmpty)
        #expect(harness.mainTurns.isEmpty)
    }
}
#endif
