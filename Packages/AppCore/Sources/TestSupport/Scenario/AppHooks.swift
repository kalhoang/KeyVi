// SPDX-License-Identifier: GPL-3.0-or-later
//
// Harness side of the app under test's integration hooks (QA-R11, PLT-R821, 13.2 "tap timeout injection (test
// hook)", "permission revocation during typing"). The app answers only in the test build that the self-hosted
// runner installs (compiled with the INTEGRATION_HOOKS condition, never in a release). The wire format is one
// shared Codable definition, Diagnostics/IntegrationHooks.swift (ADR 0502, "Integration hooks"), which the app's
// hooks server decodes and encodes too. The harness reaches the app through `AppHookClient`; the file-drop
// transport is FileDropHookChannel.swift, tests use an in-memory app.

internal import AppModel
public import Diagnostics
internal import Foundation

public enum AppHookError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No answer within the timeout: the app is not running, or it is not the hooks build.
    case timeout(command: String)
    case rejected(command: String, code: String)
    case malformedResponse(command: String)
    case missingPayload(command: String)

    public var description: String {
        switch self {
        case .timeout(let command):
            "integration hook '" + command + "' timed out (is the INTEGRATION_HOOKS test build running?)"
        case .rejected(let command, let code): "integration hook '" + command + "' rejected: " + code
        case .malformedResponse(let command): "integration hook '" + command + "' answered with malformed JSON"
        case .missingPayload(let command): "integration hook '" + command + "' answered without its payload"
        }
    }
}

/// Sends one hook command to the app under test and returns its answer. Live: `FileDropHookChannel` over the
/// app's hooks directory; tests: an in-memory app.
public protocol AppHookClient: Sendable {
    func send(_ command: AppHookCommand) async throws -> AppHookResponse
}

extension AppHookClient {
    public func state() async throws -> AppStateSnapshot {
        guard let state = try await accepted(.state).state else { throw AppHookError.missingPayload(command: "state") }
        return state
    }

    public func trigger(_ hook: AppTestHook) async throws { _ = try await accepted(.trigger(hook)) }

    public func resetMetrics() async throws { _ = try await accepted(.resetMetrics) }

    public func latencyProbe(_ profile: LatencyProbeResult.Profile) async throws -> LatencyProbeResult {
        guard let result = try await accepted(.latencyProbe(profile)).latencyProbe else {
            throw AppHookError.missingPayload(command: "latencyProbe")
        }
        return result
    }

    /// The response when `ok`, otherwise `AppHookError.rejected`.
    func accepted(_ command: AppHookCommand) async throws -> AppHookResponse {
        let response = try await send(command)
        guard response.ok else { throw AppHookError.rejected(command: command.name, code: response.error ?? "error") }
        return response
    }
}

/// Scenario expectations from the app's own state (paused, holder, first key after release).
public struct HookStateProbe: ScenarioStateProbe {
    private let hooks: any AppHookClient

    public init(hooks: any AppHookClient) { self.hooks = hooks }

    public func observe(after scenario: Scenario) async throws -> ScenarioObservation {
        let snapshot = try await hooks.state()
        return ScenarioObservation(
            paused: snapshot.passesKeysThrough,
            holderBundleId: snapshot.pauseReason == .secureInput ? snapshot.secureInputHolderBundleId : nil,
            firstKeyAfterReleaseComposed: snapshot.firstKeyAfterSecureInputReleaseComposed)
    }
}
