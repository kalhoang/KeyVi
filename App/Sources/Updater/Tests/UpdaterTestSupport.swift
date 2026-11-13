// SPDX-License-Identifier: GPL-3.0-or-later
//
// Test doubles and fixtures for the updater tests (QA-R3). Compiled only into the UpdaterTests bundle, where
// UPDATER_TESTS is set; the App target excludes this folder and would compile it to nothing anyway. Nothing here
// starts Sparkle or touches the network.

#if UPDATER_TESTS
import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import ShellCore
import Sparkle
import TestSupport
import Testing

/// Resources compiled into this test bundle by project.yml: the shipped Updates catalog (as `vi.lproj` and
/// `en.lproj` tables) and the site's `routes.mjs`. Tests never open repository files at run time: `xctest` does not
/// inherit the terminal's access to every volume, and a privacy prompt would block the run.
enum TestResources {
    struct Missing: Error, CustomStringConvertible {
        var name: String
        var description: String { "test resource \(name) is missing; check the UpdaterTests target in project.yml" }
    }

    static var bundle: Bundle { Bundle(for: FakeUpdateDriver.self) }

    /// The compiled `Updates` table of one language: key -> value.
    static func updatesTable(_ language: InterfaceLanguage) throws -> [String: String] {
        let name = StringTable.updates.rawValue
        guard
            let url = bundle.url(
                forResource: name, withExtension: "strings", subdirectory: nil, localization: language.rawValue),
            let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
                as? [String: String]
        else { throw Missing(name: "\(language.rawValue).lproj/\(name).strings") }
        return table
    }

    static func siteRoutes() throws -> String {
        guard let url = bundle.url(forResource: "routes", withExtension: "mjs") else {
            throw Missing(name: "routes.mjs")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func localizer(_ language: InterfaceLanguage) -> Localizer {
        Localizer(language: language, appBundle: bundle)
    }
}

enum UpdaterFixtures {
    static let siteHost = "updates.example.test"
    static let appName = "Fixture App"
    static let version = "1.2.3"
    /// 32 bytes, the length of an ed25519 public key.
    static let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    static func info(
        feedURL: String? = "https://\(siteHost)/appcast.xml", publicKey: String? = publicKey,
        systemProfiling: Bool = false
    ) -> [String: Any] {
        var info: [String: Any] = [
            Brand.InfoKey.displayName: appName, Brand.InfoKey.slug: "fixture", Brand.InfoKey.siteHost: siteHost,
            Brand.InfoKey.bundleIdentifier: "test.fixture.app", Brand.InfoKey.version: version,
            Brand.InfoKey.build: "42", UpdaterConfiguration.InfoKey.systemProfiling: systemProfiling,
        ]
        info[UpdaterConfiguration.InfoKey.feedURL] = feedURL
        info[UpdaterConfiguration.InfoKey.publicEDKey] = publicKey
        return info
    }

    /// A real `SPUUserUpdateState`, only to pass to `updater(_:userDidMake:forUpdate:state:)`.
    static func userUpdateState() throws -> SPUUserUpdateState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName(NSStringFromClass(SPUUserUpdateState.self), for: UserUpdateStateArchive.self)
        archiver.encode(UserUpdateStateArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let state = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: SPUUserUpdateState.self, from: archiver.encodedData)
        return try #require(state)
    }

    /// A real, never started `SPUUpdater`, only to pass to the delegate methods.
    @MainActor
    static func unstartedUpdater() -> SPUUpdater {
        let bundle = Bundle(for: FakeUpdateDriver.self)
        return SPUUpdater(
            hostBundle: bundle, applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    }
}

/// Stands in for `SPUUserUpdateState` in a keyed archive: Sparkle offers no public initializer, so the fixture
/// decodes a real instance (stage 0, not user initiated) from an archive that names Sparkle's class.
@objc(UpdaterTestsUserUpdateStateArchive)
private final class UserUpdateStateArchive: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    override init() {}
    init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}

/// Records what the controller asks of Sparkle.
@MainActor
final class FakeUpdateDriver: UpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true {
        didSet { checkWrites += 1 }
    }
    /// Sparkle's setter is a silent no-op while the bundle disallows automatic updates (`SUAllowsAutomaticUpdates`
    /// off); `ignoresDownloadWrites` reproduces that.
    var automaticallyDownloadsUpdates: Bool {
        get { storedDownloads }
        set {
            downloadWrites += 1
            if !ignoresDownloadWrites { storedDownloads = newValue }
        }
    }
    var ignoresDownloadWrites = false
    private var storedDownloads = true
    var sendsSystemProfile = true
    var startError: NSError?
    private(set) var startCount = 0
    private(set) var checkCount = 0
    private(set) var resetCount = 0
    private(set) var checkWrites = 0
    private(set) var downloadWrites = 0

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func checkForUpdates() { checkCount += 1 }
    func resetUpdateCycleAfterShortDelay() { resetCount += 1 }

    /// What Sparkle's update window does when the user flips its "automatically download" checkbox.
    func simulateWindowCheckbox(automaticallyDownloads: Bool) {
        storedDownloads = automaticallyDownloads
    }

    /// What Sparkle reads back when automatic updates are disallowed: always false, whatever was written.
    func disallowAutomaticUpdates() {
        ignoresDownloadWrites = true
        storedDownloads = false
    }
}

@MainActor
final class FakeFailurePresenter: UpdateFailurePresenting {
    var choice: UpdateFailureChoice = .close
    /// Runs when the alert would appear, so a test can check what had already happened by then.
    var onPresent: (@MainActor () -> Void)?
    private(set) var presented: [UpdateFailureContent] = []

    func present(_ content: UpdateFailureContent) -> UpdateFailureChoice {
        onPresent?()
        presented.append(content)
        return choice
    }
}

/// Keyboard idle state over a virtual clock (PLT-R1105).
@MainActor
final class IdleSimulator {
    let clock: ManualClock
    var lastKey: MonotonicInstant?
    var secureInputOn = false

    init(clock: ManualClock) { self.clock = clock }

    func pressKey() { lastKey = clock.now() }

    var state: KeyboardIdleState {
        guard let lastKey else {
            return KeyboardIdleState(secondsSinceLastKey: .infinity, secureInputOn: secureInputOn)
        }
        let seconds = Double(clock.now().nanoseconds(since: lastKey)) / 1_000_000_000
        return KeyboardIdleState(secondsSinceLastKey: seconds, secureInputOn: secureInputOn)
    }
}

/// A controller wired to fakes: a manual main queue, recorded logs, a fake Sparkle and a fake alert.
@MainActor
final class UpdaterHarness {
    let clock = ManualClock()
    let logger = RecordingLogger()
    let driver = FakeUpdateDriver()
    let presenter = FakeFailurePresenter()
    let idle: IdleSimulator
    private(set) var controller: UpdaterController!
    private(set) var openedURLs: [URL] = []
    private(set) var changes: [UpdatePreferenceChange] = []
    private(set) var factoryCalls = 0
    private(set) var reportError: UpdaterErrorHandler?
    /// Work handed to `onNextMainTurn`, run by `runMainTurn()` in order.
    private(set) var mainTurns: [@MainActor () -> Void] = []

    init(info: [String: Any] = UpdaterFixtures.info(), language: InterfaceLanguage = .vietnamese) {
        idle = IdleSimulator(clock: clock)
        let localizer = TestResources.localizer(language)
        let dependencies = UpdaterDependencies(
            info: info, onNextMainTurn: { [unowned self] in mainTurns.append($0) }, logger: logger,
            localizer: { localizer }, presenter: presenter,
            openURL: { [unowned self] in openedURLs.append($0) },
            makeDriver: { [unowned self] _, onError in
                factoryCalls += 1
                reportError = onError
                return driver
            })
        controller = UpdaterController(
            idleState: { [unowned self] in (idle.state.secondsSinceLastKey, idle.state.secureInputOn) },
            dependencies: dependencies)
        controller.onPreferenceChange = { [unowned self] in changes.append($0) }
    }

    var delegate: any SPUUpdaterDelegate { controller }

    var updateEvents: [LogEvent.UpdateEvent] {
        logger.entries.compactMap { entry in
            if case .update(let event) = entry.event { return event }
            return nil
        }
    }

    /// Lets virtual time pass for the keyboard idle state; the controller holds no timers.
    func advance(seconds: Int) { clock.advance(byMicroseconds: UInt64(seconds) * 1_000_000) }

    /// Runs the work queued for the next main-queue turn, as the main queue would.
    func runMainTurn() {
        let turns = mainTurns
        mainTurns = []
        for work in turns { work() }
    }
}
#endif
