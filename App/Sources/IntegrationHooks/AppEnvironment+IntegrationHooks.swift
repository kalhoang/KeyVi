// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composition of the integration hooks in the runner's test build (ADR 0502, "Integration hooks"): the server
// starts right after the host, so the harness's first `state` request after a launch is answered; the update check
// and the probe's typing method are read when a request asks for them.

#if INTEGRATION_HOOKS
import AppModel
import SettingsStore

extension AppEnvironment {
    func startIntegrationHooks() {
        integrationHooks.start(
            host: host, metrics: diagnostics.metrics, applicationSupport: paths.applicationSupport,
            language: language, logger: diagnostics.logger,
            method: { [weak self] in self?.settings.effective.typingMethod ?? DefaultSettings.v1.typingMethod },
            updateCheck: { [weak self] in
                guard let updater = self?.updater else { return false }
                updater.checkForUpdates()
                return true
            })
    }
}
#endif
