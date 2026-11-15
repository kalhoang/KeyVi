// SPDX-License-Identifier: GPL-3.0-or-later
//
// The services the composition root hands to the Diagnostics windows (W2-C): the report (live for the
// misbehaves panel, bound to the moment the flow opened for the bug report sheet, PLT-R1202), the Apps pane's apps
// for the sheet's picker (PRD-R47 item 1), the live focus, the guided test with the host's diagnostics
// pass-through (PLT-R1205 steps 3-5), "Use this for me now" (PLT-R540), the typing trace (PLT-R905) and the
// latency probe (PLT-R810). Workstreams W2-H, W3-B.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

extension AppEnvironment {
    func diagnosticsServices() -> DiagnosticsServices {
        let host = self.host
        let store = settingsStore
        let names = ReportAppNames()
        return DiagnosticsServices(
            brand: brand, reportForDraft: { [unowned self] draft in diagnosticsReport(draft: draft) },
            reportSession: { [unowned self] in reportBuilder() },
            recentApps: { [unowned self] in recentReportApps(names: names) }, appName: { names.name(for: $0) },
            currentFocus: { host.currentFocus() }, guidedTest: guidedTestServices(), trace: typingTraceServices(),
            latency: latencyProbeServices(), logsFolder: paths.logs,
            applyOverride: { rule in
                // PLT-R540: a "this app" result keeps the app's "type here anyway" (`UseThisForMeNow`).
                let commands = SettingsCommands(store: store)
                let now = Date()
                Task { _ = await commands.useGuidedTestResult(rule, at: now) }
            })
    }

    /// PLT-R1202: metadata only, assembled by ShellCore from the live host; conflicts are rescanned so the report
    /// does not show an app the user has quit since launch. The draft adds only the user's choices (PRD-R47).
    func diagnosticsReport(draft: BugReportDraft? = nil) -> DiagnosticsReport {
        host.rescanConflicts()
        return diagnosticsReport(context: host.reportContext(), draft: draft)
    }

    /// The report of one bug report flow. The host context (focus, decision, permissions, tap, secure input,
    /// input sources, conflicts) is read once, here, before the sheet takes the focus; later choices rebuild from
    /// it, so the focus section keeps naming the field the user was typing in and never this app's own window.
    /// Settings, metrics and health events stay live.
    func reportBuilder() -> DiagnosticsServices.ReportBuilder {
        host.rescanConflicts()
        let context = host.reportContext()
        return { [unowned self] draft in diagnosticsReport(context: context, draft: draft) }
    }

    private func diagnosticsReport(context: HostReportContext, draft: BugReportDraft?) -> DiagnosticsReport {
        // PLT-R914: the learned collision memory as a count only, nil while it is not loaded.
        let memory = settingsStore.collisionMemory
        return ReportAssembler.report(
            identity: appIdentity, system: SystemInfoReader.current(uiLanguage: language.localizer.language),
            host: context, settings: settings, metrics: diagnostics.metrics.snapshot(), health: reportHealthEvents(),
            probe: latencyProbeResult, draft: draft, now: Date(),
            learnedCollisionEntries: memory.isLoaded ? memory.entryCount : nil)
    }

    /// PLT-R1202, PRD-R46: this session's events from memory after the earlier sessions' events from the log, so
    /// a crash or tap timeout from before this launch is still in the report. The assembler lists the last 50 and
    /// counts the 24-hour tap timeouts over all of them.
    private func reportHealthEvents() -> [HealthEvent] {
        let logger = diagnostics.logger
        return diagnostics.health.reportSource { logger.earlierSessionHealthEvents(limit: $0) }
    }

    /// PLT-R1206: secure-input episodes with the likely holder's bundle ID, from the host's state changes. An
    /// episode is the time the host stays paused for secure input with one holder.
    func noteSecureInputEpisode(_ state: HostState) {
        if case .paused(.secureInput(let holder)) = state {
            diagnostics.health.noteSecureInput(holder, active: true, at: Date())
        } else {
            diagnostics.health.noteSecureInput(nil, active: false, at: Date())
        }
    }

    /// PRD-R47 item 1: the apps of the Apps pane (PRD-R34), most recent first, without this app. Names are
    /// looked up again each time the sheet opens, so apps installed or removed meanwhile show correctly.
    private func recentReportApps(names: ReportAppNames) -> [BugReportAppChoice] {
        names.reset()
        return RecentReportApps.choices(
            appModes: settings.appModes, overrides: settings.ruleOverrides, excluding: brand.bundleIdentifier,
            name: { names.name(for: $0) })
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

/// Display names for the bug report picker, the same as the Apps pane shows: the installed app's name from
/// LaunchServices, else the name in the bundled compatibility matrix (`AppIdentityCache`); nil leaves the
/// bundle ID. Loaded on demand on the main thread, only while a report sheet opens.
@MainActor
final class ReportAppNames {
    private let identities = AppIdentityCache()
    private lazy var matrix: MatrixDocument? = SettingsResources.bundledMatrix()

    func reset() { identities.removeAll() }

    func name(for bundle: BundleKey) -> String? {
        let name = identities.name(for: bundle, matrixName: matrix?.appEntry(for: bundle)?.displayName)
        return name == bundle.rawValue ? nil : name
    }
}
