// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Sparkle side of the wrapper (PLT-R104, ADR 0304). `SPUUpdater` with Sparkle's standard user driver, which
// is what `SPUStandardUpdaterController` builds internally, except that the user driver is a subclass whose only
// change is the error alert: PRD-R43 needs our own copy with "Thử lại" and "Tải từ trang web", and
// `SPUStandardUpdaterController` offers no way to replace Sparkle's single-button error alert. Every other window
// (update found, release notes, progress, "Install and Relaunch") is Sparkle's standard UI (PRD-R50).

import Foundation
import Sparkle

/// The part of `SPUUpdater` the controller uses, so tests drive the controller with a fake and never construct a
/// started updater (no network in tests).
@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var sendsSystemProfile: Bool { get set }
    func start() throws
    func checkForUpdates()
    func resetUpdateCycleAfterShortDelay()
}

extension SPUUpdater: UpdateDriving {}

/// Called with Sparkle's error and the acknowledgement Sparkle waits for before it ends the session.
typealias UpdaterErrorHandler = @MainActor (_ error: NSError, _ acknowledgement: @escaping () -> Void) -> Void

/// Builds the driver once the controller exists (the controller is the updater's delegate).
typealias UpdateDriverFactory =
    @MainActor (_ delegate: any SPUUpdaterDelegate, _ onError: @escaping UpdaterErrorHandler) -> any UpdateDriving

enum SparkleDriver {
    /// Production factory for the app bundle. Sparkle keeps the user driver; the controller keeps the updater.
    static func factory(bundle: Bundle) -> UpdateDriverFactory {
        { delegate, onError in
            let userDriver = FailureReportingUserDriver(hostBundle: bundle, delegate: nil)
            userDriver.onError = onError
            return SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: delegate)
        }
    }
}

/// Sparkle's standard user driver with the error alert handed to the controller (PRD-R43).
@MainActor
final class FailureReportingUserDriver: SPUStandardUserDriver {
    var onError: UpdaterErrorHandler?

    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard let onError else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }
        onError(error as NSError, acknowledgement)
    }
}
