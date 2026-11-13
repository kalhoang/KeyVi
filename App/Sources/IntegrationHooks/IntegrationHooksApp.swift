// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app side of the integration hooks (ADR 0502, "Integration hooks"), compiled only into the self-hosted
// runner's test build: the INTEGRATION_HOOKS condition is set by the Integration configuration
// (Config/Integration.xcconfig) and never by Release; scripts/verify-release.sh fails a release app that carries
// `IntegrationHooksBuild.marker`. Thin adapter: the server, the directory rules, the commands and the host
// mapping are AppCore code (InputHost/IntegrationHooks) covered by `swift test`.

#if INTEGRATION_HOOKS
import AppModel
import Diagnostics
import Foundation
import InputHost
import ShellCore

/// The one string only this build carries. It labels the hooks' dispatch queue, so it is used at run time and
/// stays in the executable; verify-release.sh greps release executables for it.
enum IntegrationHooksBuild {
    static let marker = "INTEGRATION_HOOKS test build: file-drop integration hooks"
}

/// Owns the hooks of one app run: wraps the host's tap factory and trust check before the host is built, then
/// starts the server once the host runs.
@MainActor
final class IntegrationHooksApp {
    let instruments: IntegrationHookInstruments
    private var server: IntegrationHookServer?
    private var probe: HookLatencyProbe?

    /// Instruments `dependencies` (tap timeout, revocable trust check) and returns the ones the host must use.
    init(instrumenting dependencies: inout InputHostDependencies) {
        let (instrumented, instruments) = IntegrationHookInstruments.instrument(dependencies)
        dependencies = instrumented
        self.instruments = instruments
    }

    /// Starts answering `<application support>/IntegrationHooks/request-<n>.json`. `updateCheck` returns false
    /// while the updater is not running yet.
    func start(
        host: InputHostController, metrics: PlatformMetrics, applicationSupport: URL, language: InterfaceLanguageModel,
        logger: any DiagnosticsLogging, method: @escaping @MainActor () -> TypingMethod,
        updateCheck: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard server == nil else { return }
        let probe = HookLatencyProbe(host: host, metrics: metrics, language: language, method: method)
        self.probe = probe
        let actions = InputHostHookActions(
            host: host, metrics: metrics, instruments: instruments,
            latencyProbe: { profile in await probe.run(profile) }, updateCheck: updateCheck)
        let directory = PosixHookDirectory.directory(applicationSupport: applicationSupport)
        let queue = DispatchQueue(label: IntegrationHooksBuild.marker, qos: .utility)
        let server = IntegrationHookServer(
            files: PosixHookDirectory(directory: directory),
            watcher: VnodeDirectoryWatcher(directory: directory, queue: queue), actions: actions, logger: logger)
        self.server = server
        // An unusable directory leaves the build silent; the server has logged the reason code (runbook section 8).
        Task { try? await server.start() }
    }

    func stop() {
        guard let server else { return }
        Task { await server.stop() }
    }
}
#endif
