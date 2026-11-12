// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Composition root (workstream W2-A). Builds every production service once, wires AppCore modules together
// and owns the window controllers. Main actor only.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import Injection
import InputHost
import SettingsStore
import ShellCore

@MainActor
final class AppEnvironment {
    let brand: Brand
    let language: InterfaceLanguageModel
    let settingsStore: SettingsStore
    let host: InputHostController
    let statusItem: StatusItemController
    let updater: UpdaterController

    /// Launch order (S1 target 300 ms to tap active): LaunchGuard -> AppLocationCheck (move offer before any
    /// permission request, PLT-R710) -> SettingsStore.load -> RulesLoader.load(compat-rules.json) ->
    /// InputHostController.start -> StatusItemController -> onboarding if not completed (PRD-R40, PRD-R42)
    /// -> UpdaterController.start.
    init(bundle: Bundle) { unimplemented() }

    func start() { unimplemented() }
    /// Quit: flush settings (PLT-R1003), stop the host (tap removed), let Sparkle install on quit (D20).
    func terminate() { unimplemented() }
    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func handle(url: URL) { unimplemented() }
}
