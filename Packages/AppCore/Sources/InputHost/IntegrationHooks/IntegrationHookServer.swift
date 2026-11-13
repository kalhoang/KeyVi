// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The app side of the integration hooks (ADR 0502, "Integration hooks"; W3-A): for every `request-<n>.json` in
// the hooks directory, run the command and answer `response-<n>.json` carrying the request's own sequence number.
// Only the INTEGRATION_HOOKS test build creates a server (App/Sources/IntegrationHooks); it starts with one scan, so
// a request written before the watcher began is answered too, then scans again on every directory change. One
// command runs at a time: a request arriving meanwhile is answered `busy`. Responses carry codes and numbers only
// (PLT-R901); requests are never deleted and never answered twice.

public import Diagnostics
internal import Foundation

/// What the hooks can do to the running app. Production: `InputHostHookActions`; tests: fakes.
public protocol IntegrationHookActions: Sendable {
    func state() async -> AppStateSnapshot
    func resetMetrics() async
    /// The tap timed out and recovered (PLT-R330), or why not.
    func simulateTapTimeout() async -> HookActionOutcome
    /// Revokes (`true`) or restores the Accessibility answer of the trust check and waits until the host acted on
    /// it (PLT-R730 fail-open, 7.3 re-grant).
    func setAccessibilityRevoked(_ revoked: Bool) async -> HookActionOutcome
    func runLatencyProbe(_ profile: LatencyProbeResult.Profile) async -> LatencyProbeOutcome
    func checkForUpdates() async -> HookActionOutcome
}

public enum HookActionOutcome: Sendable, Hashable {
    case done
    /// Not possible in this state: no tap to time out, no updater yet (`unsupported`).
    case unavailable
    /// The host did not reach the expected state in time (`busy`).
    case timedOut
}

public enum LatencyProbeOutcome: Sendable, Hashable {
    case result(LatencyProbeResult)
    /// No Latin layout for the probe script (`unsupported`).
    case unavailable
    /// The probe window lost focus, so the run stopped (`busy`).
    case interrupted
}

public actor IntegrationHookServer {
    /// Requests are about 100 bytes; anything larger is refused unread beyond this cap.
    public static let maximumRequestBytes = 4_096
    /// Sequence numbers already answered or refused, so a scan that runs while the harness has not yet removed
    /// a request does not answer it again. Bounded: the response file guards older ones.
    static let rememberedSequences = 256

    private let files: any IntegrationHookFileAccess
    private let watcher: any DirectoryChangeWatching
    private let actions: any IntegrationHookActions
    private var running: UInt64?
    private var handled: [UInt64] = []
    private var started = false

    public init(
        files: any IntegrationHookFileAccess, watcher: any DirectoryChangeWatching, actions: any IntegrationHookActions
    ) {
        self.files = files
        self.watcher = watcher
        self.actions = actions
    }

    /// Prepares the directory (0700, refusing a link or another user's directory), starts the watcher and scans
    /// once. Throws when the directory cannot be used; the build then simply does not answer.
    public func start() async throws(HookDirectoryError) {
        guard !started else { return }
        try files.prepare()
        try watcher.start { [weak self] change in
            guard let self else { return }
            Task { await self.changed(change) }
        }
        started = true
        await scan()
    }

    public func stop() {
        guard started else { return }
        started = false
        watcher.stop()
    }

    /// The directory was deleted or renamed: prepare it again and watch the new one.
    func changed(_ change: DirectoryChange) async {
        guard started else { return }
        if change == .replaced {
            watcher.stop()
            started = false
            try? await start()
            return
        }
        await scan()
    }

    /// One pass over the directory: answers every request that has no answer yet, in sequence order.
    public func scan() async {
        for sequence in files.requestSequences() where running != sequence && !handled.contains(sequence) {
            if files.responseExists(sequence) {
                remember(sequence)
                continue
            }
            switch files.readRequest(sequence, maxBytes: Self.maximumRequestBytes) {
            case .failure(.missing): continue
            case .failure(.symbolicLink), .failure(.notRegularFile), .failure(.foreignOwner):
                remember(sequence)  // refused without an answer: not the harness's file
            case .failure(.tooLarge), .failure(.unreadable):
                answer(.refused(sequence: sequence, .unsupported))
            case .success(let data):
                await handle(data, sequence: sequence)
            }
        }
    }

    private func handle(_ data: Data, sequence: UInt64) async {
        guard let request = try? JSONDecoder().decode(AppHookRequest.self, from: data),
            request.formatVersion == AppHookRequest.formatVersion, request.sequence == sequence
        else { return answer(.refused(sequence: sequence, .unsupported)) }
        switch AppHookCommand.parse(name: request.command, profile: request.profile) {
        case .failure(let code): answer(.refused(sequence: sequence, code))
        case .success(let command):
            guard running == nil else { return answer(.refused(sequence: sequence, .busy)) }
            running = sequence
            let response = await execute(command, sequence: sequence)
            running = nil
            answer(response)
        }
    }

    private func execute(_ command: AppHookCommand, sequence: UInt64) async -> AppHookResponse {
        switch command {
        case .state: return AppHookResponse(sequence: sequence, state: await actions.state())
        case .resetMetrics:
            await actions.resetMetrics()
            return AppHookResponse(sequence: sequence)
        case .trigger(.tapTimeout): return Self.response(await actions.simulateTapTimeout(), sequence)
        case .trigger(.revokePermission): return Self.response(await actions.setAccessibilityRevoked(true), sequence)
        case .trigger(.restorePermission):
            return Self.response(await actions.setAccessibilityRevoked(false), sequence)
        case .latencyProbe(let profile):
            switch await actions.runLatencyProbe(profile) {
            case .result(let result): return AppHookResponse(sequence: sequence, latencyProbe: result)
            case .unavailable: return .refused(sequence: sequence, .unsupported)
            case .interrupted: return .refused(sequence: sequence, .busy)
            }
        case .checkForUpdates: return Self.response(await actions.checkForUpdates(), sequence)
        }
    }

    private static func response(_ outcome: HookActionOutcome, _ sequence: UInt64) -> AppHookResponse {
        switch outcome {
        case .done: AppHookResponse(sequence: sequence)
        case .unavailable: .refused(sequence: sequence, .unsupported)
        case .timedOut: .refused(sequence: sequence, .busy)
        }
    }

    private func answer(_ response: AppHookResponse) {
        remember(response.sequence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(response) else { return }
        try? files.writeResponse(data, sequence: response.sequence)
    }

    private func remember(_ sequence: UInt64) {
        handled.append(sequence)
        if handled.count > Self.rememberedSequences { handled.removeFirst(handled.count - Self.rememberedSequences) }
    }
}
