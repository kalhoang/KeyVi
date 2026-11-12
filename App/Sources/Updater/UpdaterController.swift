// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Thin wrapper around Sparkle 2 (PLT-R1101-R1110, PRD-R50-R55, docs/decisions/0304-sparkle-version-pin.md).
// Workstream W2-D.

import AppKit
import AppModel
import ShellCore
import Sparkle

@MainActor
final class UpdaterController: NSObject, UpdaterControlling {
    /// `idleState` answers "seconds since the last key press, and is secure input on?" for the relaunch policy
    /// (PLT-R1105).
    init(idleState: @escaping @MainActor () -> (secondsSinceLastKey: Double, secureInputOn: Bool)) {
        unimplemented()
    }

    func start() { unimplemented() }

    var canCheckForUpdates: Bool { unimplemented() }
    var automaticallyChecksForUpdates: Bool {
        get { unimplemented() }
        set { unimplemented() }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { unimplemented() }
        set { unimplemented() }
    }
    var channel: UpdateChannelSelection {
        get { unimplemented() }
        set { unimplemented() }
    }
    func checkForUpdates() { unimplemented() }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// `["beta"]` only after the user opted in (PLT-R1101, PRD-R53).
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> { unimplemented() }

    /// Install on quit by default; call `immediateInstallHandler` only after 60 s without a key press and with
    /// secure input off (PLT-R1105).
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool { unimplemented() }
}
