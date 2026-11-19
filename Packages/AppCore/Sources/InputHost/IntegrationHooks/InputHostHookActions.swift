// SPDX-License-Identifier: GPL-3.0-or-later
//
// The integration hooks' actions on the running input host (ADR 0502, "Integration hooks"): the state snapshot
// from `HostState`, `HostCounters` and `PlatformMetrics`; the metrics reset; the tap timeout and the permission
// revocation through the instrumented seams (`IntegrationHookInstruments`), each answered only once the host has
// acted, so the harness's next key lands on the recovered or failed-open tap. The latency probe window and the
// update check are App features, passed in as closures by App/Sources/IntegrationHooks.

internal import AppModel
public import Diagnostics
internal import Foundation
public import RealtimeSupport

/// A bounded wait for a state the main thread reaches after a hop (the permission monitor and the tap's notices
/// both hop to main). Runs on the hooks' task, never on the tap or main thread; tests pass a `sleep` that drains
/// their manual hop instead of sleeping.
public struct HookConditionWait: Sendable {
    public var timeout: TimeSpan
    public var step: TimeSpan
    public var sleep: @Sendable (TimeSpan) async -> Void

    public init(timeout: TimeSpan, step: TimeSpan, sleep: @escaping @Sendable (TimeSpan) async -> Void) {
        self.timeout = timeout
        self.step = step
        self.sleep = sleep
    }

    /// 2 s in 10 ms steps: the recovery takes one hop to main, far below that.
    public static let standard = HookConditionWait(timeout: .seconds(2), step: .milliseconds(10)) { step in
        try? await Task.sleep(nanoseconds: step.unsignedNanoseconds)
    }

    /// True as soon as `condition` holds on the main actor; false after `timeout`.
    public func until(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        var waited = TimeSpan.zero
        while true {
            if await MainActor.run(body: condition) { return true }
            guard waited < timeout else { return false }
            await sleep(step)
            waited += step
        }
    }
}

public final class InputHostHookActions: IntegrationHookActions {
    public typealias LatencyProbe = @Sendable (LatencyProbeResult.Profile) async -> LatencyProbeOutcome
    public typealias UpdateCheck = @MainActor @Sendable () -> Bool

    private let host: InputHostController
    private let metrics: PlatformMetrics
    private let instruments: IntegrationHookInstruments
    private let processIdentifier: Int32
    private let wait: HookConditionWait
    private let latencyProbe: LatencyProbe
    private let updateCheck: UpdateCheck

    /// `updateCheck` returns false while the updater is not running yet. `processIdentifier` nil: this process.
    public init(
        host: InputHostController, metrics: PlatformMetrics, instruments: IntegrationHookInstruments,
        processIdentifier: Int32? = nil, wait: HookConditionWait = .standard,
        latencyProbe: @escaping LatencyProbe, updateCheck: @escaping UpdateCheck
    ) {
        self.host = host
        self.metrics = metrics
        self.instruments = instruments
        self.processIdentifier = processIdentifier ?? ProcessInfo.processInfo.processIdentifier
        self.wait = wait
        self.latencyProbe = latencyProbe
        self.updateCheck = updateCheck
    }

    public func state() async -> AppStateSnapshot {
        let host = self.host
        let metrics = self.metrics
        let pid = processIdentifier
        return await MainActor.run {
            AppStateSnapshot(
                processIdentifier: pid, hostState: host.state,
                firstKeyAfterSecureInputReleaseComposed: host.counters.firstKeyAfterSecureInputReleaseComposed,
                tapRecoveries: host.counters.tapRecoveryCount,
                engineResetsAfterTapRecovery: host.counters.engineResetsAfterTapRecoveryCount,
                corrections: host.counters.correctionCount, correctionUndos: host.counters.correctionUndoCount,
                metrics: metrics.snapshot())
        }
    }

    public func resetMetrics() async { metrics.reset() }

    /// PLT-R330, QA-R11: the tap is disabled and gets `tapDisabledByTimeout`; done once the main thread has
    /// re-enabled it (the recovery count moved).
    public func simulateTapTimeout() async -> HookActionOutcome {
        let host = self.host
        let before = await MainActor.run { host.counters.tapRecoveryCount }
        guard instruments.tapFactory.simulateTimeout() else { return .unavailable }
        return await wait.until { host.counters.tapRecoveryCount > before } ? .done : .timedOut
    }

    /// PLT-R730: revoked, the next check fails the host open (keys pass untouched, the tap is removed); restored,
    /// the host creates its tap again without a relaunch (7.3). Done once the host state shows it.
    public func setAccessibilityRevoked(_ revoked: Bool) async -> HookActionOutcome {
        instruments.permissions.setRevoked(revoked)
        let host = self.host
        await MainActor.run { _ = host.refreshPermissions() }
        let reached = await wait.until {
            switch host.state {
            case .failOpen, .noPermission: revoked
            case .starting: false
            case .ready, .paused: !revoked
            }
        }
        return reached ? .done : .timedOut
    }

    public func runLatencyProbe(_ profile: LatencyProbeResult.Profile) async -> LatencyProbeOutcome {
        await latencyProbe(profile)
    }

    public func checkForUpdates() async -> HookActionOutcome {
        await MainActor.run(body: updateCheck) ? .done : .unavailable
    }
}
