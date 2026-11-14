// SPDX-License-Identifier: GPL-3.0-or-later
//
// The composition root's wiring of the dev builds' typing recorder (PLT-R904A, ADR 0007): started with the shell,
// fed settings and mode changes, shown on the status item. Debug configuration only; the recorder itself is
// `DiagnosticsWiring.devRecorder`.

#if DEV_RECORDER
import AppKit
import AppModel
import InputHost
import SettingsStore
import ShellCore

extension AppEnvironment {
    /// With the shell: the badge and the menu items appear, then the recorder starts.
    func startDevRecorder(statusItem: StatusItemController, settings: SettingsState) {
        let controller = diagnostics.devRecorder
        let language = self.language
        controller.localizer = { language.localizer }
        statusItem.devRecorder = controller
        controller.start(appVersion: bundleVersion, host: host, settings: settings)
    }

    func noteDevSettings(_ state: SettingsState) { diagnostics.devRecorder.noteSettings(state) }

    func noteDevMode(_ mode: TypingMode, manual: Bool, bundle: BundleKey?) {
        diagnostics.devRecorder.noteMode(mode, manual: manual, bundle: bundle)
    }
}
#endif
