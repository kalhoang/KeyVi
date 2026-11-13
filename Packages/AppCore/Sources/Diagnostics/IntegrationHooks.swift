// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wire format of the integration hooks (ADR 0502, "Integration hooks"; QA-R11, PLT-R821, 13.2 "tap timeout
// injection (test hook)"). One Codable definition shared by the harness (TestSupport, FileDropHookChannel) and the
// app's INTEGRATION_HOOKS test build (InputHost `IntegrationHookServer`, App/Sources/IntegrationHooks). Release
// builds link these value types but never answer a request: the watcher exists only under the compilation
// condition. Metadata only (PLT-R901): no typed text, window titles, URLs or app names ever reach a response.

public import AppModel

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

    /// The command a request names. `unknownCommand` for a name outside the contract, `unsupported` for
    /// `latencyProbe` without its profile.
    public static func parse(name: String, profile: LatencyProbeResult.Profile?) -> Result<
        AppHookCommand, AppHookErrorCode
    > {
        switch name {
        case "state": return .success(.state)
        case "resetMetrics": return .success(.resetMetrics)
        case "checkForUpdates": return .success(.checkForUpdates)
        case "latencyProbe":
            guard let profile else { return .failure(.unsupported) }
            return .success(.latencyProbe(profile))
        default:
            guard let hook = AppTestHook(rawValue: name) else { return .failure(.unknownCommand) }
            return .success(.trigger(hook))
        }
    }
}

/// Why the app refused a request. The wire carries the raw value in `AppHookResponse.error`, never content.
public enum AppHookErrorCode: String, Error, Sendable, Hashable, Codable, CaseIterable {
    /// The command name is not part of the contract.
    case unknownCommand
    /// The request cannot be served by this build or right now: an unknown `formatVersion`, a malformed or
    /// oversized request, `latencyProbe` without a profile or without a Latin layout, no tap to time out, no
    /// updater yet.
    case unsupported
    /// Another request is still running (one at a time), or the latency probe window lost focus.
    case busy
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

    /// The snapshot of a host state (02-platform.md 2.1). Only codes cross the wire: the input source name of
    /// `nonLatinInputSource`, the rule of `passThroughRule` and the holder's display name are dropped (PLT-R901);
    /// the holder appears as its bundle ID only, and only while paused for secure input.
    public init(
        processIdentifier: Int32, hostState: HostState, firstKeyAfterSecureInputReleaseComposed: Bool?,
        tapRecoveries: UInt64, engineResetsAfterTapRecovery: UInt64, metrics: MetricsSnapshot
    ) {
        self.init(
            processIdentifier: processIdentifier, state: .starting,
            firstKeyAfterSecureInputReleaseComposed: firstKeyAfterSecureInputReleaseComposed,
            tapRecoveries: tapRecoveries, engineResetsAfterTapRecovery: engineResetsAfterTapRecovery, metrics: metrics)
        switch hostState {
        case .noPermission: state = .noPermission
        case .starting: state = .starting
        case .ready(let typingMode):
            state = .ready
            mode = typingMode
        case .paused(let reason):
            state = .paused
            pauseReason = reason.code
            if case .secureInput(let holder) = reason { secureInputHolderBundleId = holder?.bundle }
        case .failOpen(let reason):
            state = .failOpen
            failOpenReason = reason
        }
    }

    /// Keys pass through untransformed: paused (any reason) or failed open.
    public var passesKeysThrough: Bool { state == .paused || state == .failOpen || state == .noPermission }
}

/// `response-<sequence>.json`.
public struct AppHookResponse: Sendable, Hashable, Codable {
    public var formatVersion: Int
    public var sequence: UInt64
    public var ok: Bool
    /// Error code when `ok` is false (`AppHookErrorCode` raw value), never content. A string on the wire, so a
    /// harness also reads a code a newer build adds.
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

    /// A refusal carrying the request's sequence number.
    public static func refused(sequence: UInt64, _ code: AppHookErrorCode) -> AppHookResponse {
        AppHookResponse(sequence: sequence, ok: false, error: code.rawValue)
    }

    /// The error as a known code; nil when `ok` or when the code is unknown to this build.
    public var errorCode: AppHookErrorCode? { error.flatMap(AppHookErrorCode.init(rawValue:)) }
}

/// File names of the hooks directory (`~/Library/Application Support/<storage folder>/IntegrationHooks/`).
public enum IntegrationHookFiles {
    /// Directory name below the app's Application Support folder.
    public static let directoryName = "IntegrationHooks"
    static let requestPrefix = "request-"
    static let responsePrefix = "response-"
    static let suffix = ".json"

    public static func requestName(_ sequence: UInt64) -> String { requestPrefix + String(sequence) + suffix }
    public static func responseName(_ sequence: UInt64) -> String { responsePrefix + String(sequence) + suffix }

    /// The sequence of `request-<n>.json` (decimal digits only, no sign, no leading `+`, fits UInt64); nil for
    /// every other name, including the harness's temporary files.
    public static func requestSequence(fileName name: String) -> UInt64? {
        guard name.hasPrefix(requestPrefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(requestPrefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.count <= 20, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return UInt64(digits)
    }
}
