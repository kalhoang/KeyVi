// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The services the composition root hands to the Diagnostics windows (W2-C): the live focus, the guided test
// with the host's diagnostics pass-through (PLT-R1205 steps 3-5), "Use this for me now" (PLT-R540), the typing
// trace (PLT-R905) and the latency probe (PLT-R810). Workstream W2-H.

import AppKit
import AppModel
import Diagnostics
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

extension AppEnvironment {
    func diagnosticsServices() -> DiagnosticsServices {
        let host = self.host
        let store = settingsStore
        return DiagnosticsServices(
            brand: brand, reportForDraft: { [unowned self] draft in diagnosticsReport(draft: draft) },
            currentFocus: { host.currentFocus() }, guidedTest: guidedTestServices(), trace: typingTraceServices(),
            latency: latencyProbeServices(), logsFolder: paths.logs,
            applyOverride: { rule in
                guard let stored = GuidedTestOverride.stored(rule, at: Date()) else { return }
                Task { await store.addRuleOverride(stored) }
            })
    }

    /// PLT-R1205 step 3: with this the panel offers the guided test (`canOfferGuidedTest`). The runner shares
    /// the launch's event marker; the pass-through is balanced by the panel around every candidate.
    private func guidedTestServices() -> GuidedTestServices {
        let host = self.host
        return GuidedTestServices(
            runner: host.makeGuidedTestRunner(), setPassThrough: { host.setDiagnosticsPassThrough($0) },
            macOSVersion: InputHostController.macOSVersion.original, today: { TextFocusOverride.day(Date()) })
    }

    /// PLT-R905: the icon changes for the whole recording.
    private func typingTraceServices() -> TypingTraceServices {
        TypingTraceServices(
            capture: diagnostics.capture, scheduler: DispatchTimerScheduler(queue: utility),
            wallClock: SystemWallClock(),
            captureStateChanged: { [weak self] _ in self?.updateIcon() })
    }

    /// PLT-R810: the driver and the probe share the tap's clock base; the result goes into the next report.
    private func latencyProbeServices() -> LatencyProbeServices {
        let host = self.host
        return LatencyProbeServices(
            driver: host.makeLatencyProbeDriver(), metrics: diagnostics.metrics, clock: MachClock(),
            wallClock: SystemWallClock(), layout: { host.currentLayoutTable() },
            method: { [weak self] in self?.settings.effective.typingMethod ?? DefaultSettings.v1.typingMethod },
            onResult: { [weak self] result in self?.latencyProbeResult = result })
    }
}
