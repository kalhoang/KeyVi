// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Harness side of the app under test's integration hooks (QA-R11, PLT-R821, 13.2 "tap timeout injection (test
// hook)", "permission revocation during typing"). The app answers only in the test build that the self-hosted
// runner installs (compiled with the INTEGRATION_HOOKS condition, never in a release); the wire format below is
// the contract (ADR 0502, "Integration hooks"). The harness reaches the app through `AppHookClient`; the
// file-drop transport is FileDropHookChannel.swift, tests use an in-memory app.

public import AppModel
public import Diagnostics
internal import Foundation

/// A test hook a scenario triggers (`testHook` setup step).
public enum AppTestHook: String, Sendable, Hashable, Codable, CaseIterable {
    /// The app disables its event tap as macOS does after a callback timeout, then runs its normal recovery
    /// (PLT-R330). QA-R11: the engine state MUST be reset after recovery.
    case tapTimeout
    /// The app's trust check reports Accessibility as revoked (PLT-R730 fail-open, PRD-R44).
    case revokePermission
    /// Ends `revokePermission`: the trust check reports the real value again, so the app re-creates its tap
    /// without a relaunch (7.3).
    case restorePermission
}

/// One request to the app under test.
public enum AppHookCommand: Sendable, Hashable {
    /// Host state, secure-input holder and the PLT-R801 metrics.
    case state
    /// Zeroes every histogram and counter of `PlatformMetrics`, so a measured workload starts clean.
    case resetMetrics
    case trigger(AppTestHook)
    /// Runs the built-in latency probe (PLT-R810) with one profile and returns its T2 and T4 percentiles.
    case latencyProbe(LatencyProbeResult.Profile)
    /// Starts an update check now, as "Check for Updates" does (13.7 egress test).
    case checkForUpdates

    /// Wire name of the command.
    public var name: String {
        switch self {
        case .state: "state"
        case .resetMetrics: "resetMetrics"
        case .trigger(let hook): hook.rawValue
        case .latencyProbe: "latencyProbe"
        case .checkForUpdates: "checkForUpdates"
        }
    }
}

/// `request-<sequence>.json`.
public struct AppHookRequest: Sendable, Hashable, Codable {
    public static let formatVersion = 1
    public var formatVersion: Int
    public var sequence: UInt64
    public var command: String
    public var profile: LatencyProbeResult.Profile?

    public init(sequence: UInt64, command: AppHookCommand) {
        formatVersion = Self.formatVersion
        self.sequence = sequence
        self.command = command.name
        if case .latencyProbe(let profile) = command { self.profile = profile }
    }
}

/// App state for scenario expectations and soak counters. Metadata only (PLT-R901): no text, no titles.
public struct AppStateSnapshot: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable { case noPermission, starting, ready, paused, failOpen }

    public var processIdentifier: Int32
    public var state: State
    /// The mode while `ready`.
    public var mode: TypingMode?
    public var pauseReason: PauseCode?
    public var failOpenReason: FailOpenReason?
    /// Likely holder of Secure Event Input while paused for it (PLT-R396).
    public var secureInputHolderBundleId: BundleKey?
    /// PLT-R398B: whether the first key-down after the most recent secure-input release was composed; nil before
    /// the first release of this process.
    public var firstKeyAfterSecureInputReleaseComposed: Bool?
    /// Tap re-enables after a timeout (system or `tapTimeout` hook) since launch.
    public var tapRecoveries: UInt64
    /// Of those, recoveries after which the engine state was reset (QA-R11 expects every one).
    public var engineResetsAfterTapRecovery: UInt64
    public var metrics: MetricsSnapshot

    public init(
        processIdentifier: Int32, state: State, mode: TypingMode? = nil, pauseReason: PauseCode? = nil,
        failOpenReason: FailOpenReason? = nil, secureInputHolderBundleId: BundleKey? = nil,
        firstKeyAfterSecureInputReleaseComposed: Bool? = nil, tapRecoveries: UInt64 = 0,
        engineResetsAfterTapRecovery: UInt64 = 0, metrics: MetricsSnapshot
    ) {
        self.processIdentifier = processIdentifier
        self.state = state
        self.mode = mode
        self.pauseReason = pauseReason
        self.failOpenReason = failOpenReason
        self.secureInputHolderBundleId = secureInputHolderBundleId
        self.firstKeyAfterSecureInputReleaseComposed = firstKeyAfterSecureInputReleaseComposed
        self.tapRecoveries = tapRecoveries
        self.engineResetsAfterTapRecovery = engineResetsAfterTapRecovery
        self.metrics = metrics
    }

    /// Keys pass through untransformed: paused (any reason) or failed open.
    public var passesKeysThrough: Bool { state == .paused || state == .failOpen || state == .noPermission }
}

/// `response-<sequence>.json`.
public struct AppHookResponse: Sendable, Hashable, Codable {
    public var formatVersion: Int
    public var sequence: UInt64
    public var ok: Bool
    /// Error code when `ok` is false (`unknownCommand`, `unsupported`, `busy`), never content.
    public var error: String?
    public var state: AppStateSnapshot?
    public var latencyProbe: LatencyProbeResult?

    public init(
        sequence: UInt64, ok: Bool = true, error: String? = nil, state: AppStateSnapshot? = nil,
        latencyProbe: LatencyProbeResult? = nil
    ) {
        formatVersion = AppHookRequest.formatVersion
        self.sequence = sequence
        self.ok = ok
        self.error = error
        self.state = state
        self.latencyProbe = latencyProbe
    }
}

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
