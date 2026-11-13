// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The Sparkle adapter without starting Sparkle: the production factory builds an unstarted `SPUUpdater` for the
// given bundle, the user driver hands errors to the controller (PRD-R43), and the live wiring follows the
// interface language (D18). Nothing here checks for updates or touches the network.

#if UPDATER_TESTS
import AppModel
import Foundation
import ShellCore
import Sparkle
import Testing

@MainActor
@Suite struct SparkleDriverTests {
    final class NullDelegate: NSObject, SPUUpdaterDelegate {}

    @Test("The production factory builds an SPUUpdater for the given bundle without starting it")
    func factoryBuildsUnstartedUpdater() throws {
        let bundle = TestResources.bundle
        let delegate = NullDelegate()
        let driver = SparkleDriver.factory(bundle: bundle)(delegate) { _, acknowledgement in acknowledgement() }
        let updater = try #require(driver as? SPUUpdater)
        #expect(updater.hostBundle == bundle)
        #expect(!updater.sessionInProgress)
    }

    @Test("PRD-R43: the user driver hands Sparkle's error and acknowledgement to the controller")
    func userDriverForwardsErrors() {
        let userDriver = FailureReportingUserDriver(hostBundle: TestResources.bundle, delegate: nil)
        var received: [Int] = []
        var acknowledged = 0
        userDriver.onError = { error, acknowledgement in
            received.append(error.code)
            acknowledgement()
        }
        userDriver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 2001)) { acknowledged += 1 }
        #expect(received == [2001])
        #expect(acknowledged == 1)
    }

    @Test("Live wiring reads the bundle and follows the selected interface language")
    func liveDependencies() {
        let bundle = TestResources.bundle
        let language = InterfaceLanguageModel(language: .english, appBundle: bundle)
        let live = UpdaterDependencies.live(bundle: bundle, language: language)
        #expect((live.info["CFBundleIdentifier"] as? String) == bundle.bundleIdentifier)
        #expect(live.localizer().language == .english)
        language.select(.vietnamese)
        #expect(live.localizer().language == .vietnamese)
        #expect(live.presenter is AlertUpdateFailurePresenter)
        #expect(UpdaterDependencies.live(bundle: bundle).localizer().language == .vietnamese)
    }
}
#endif
