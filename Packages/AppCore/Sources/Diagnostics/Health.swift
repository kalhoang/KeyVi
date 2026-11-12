// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

/// Metadata-only health event (PLT-R1206).
public struct HealthEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, flush, fallbackActivated,
            axCircuitBreakerTrip, echoLoss, postingBroken, permissionTransition, secureInputEpisode,
            ruleLoadError, ruleTie, placeholderResidue, pasteRestoreSkipped, generationDiscard,
            settingsRecovered, settingsNewerSchema, safeModeEntered
    }

    public enum Detail: Sendable, Hashable, Codable {
        case count(Int)
        case durationMicroseconds(UInt64)
        case permission(PermissionKind, from: PermissionState, to: PermissionState)
        case fallback(from: InjectionStrategy, to: InjectionStrategy)
        case secureInput(holder: BundleKey?, holderKind: SecureInputHolder.Kind?, durationMilliseconds: UInt64)
        case failOpen(FailOpenReason)
    }

    public var kind: Kind
    public var at: Date
    public var bundle: BundleKey?
    public var rule: RuleID?
    public var detail: Detail?

    public init(kind: Kind, at: Date, bundle: BundleKey? = nil, rule: RuleID? = nil, detail: Detail? = nil) {
        self.kind = kind
        self.at = at
        self.bundle = bundle
        self.rule = rule
        self.detail = detail
    }
}

/// In-memory ring of recent health events (the report shows the last 50, PLT-R1202), mirrored to the log
/// file so events from before a crash remain explainable (PRD-R46). Not used on the tap thread.
public final class HealthEventLog: Sendable {
    public init(capacity: Int = 256) { unimplemented() }
    public func record(_ event: HealthEvent) { unimplemented() }
    public func recent(limit: Int) -> [HealthEvent] { unimplemented() }
    /// Count of events of `kind` within `window` before `now` (PLT-R330 "more than 3 within 10 minutes").
    public func count(of kind: HealthEvent.Kind, within window: TimeInterval, now: Date) -> Int { unimplemented() }
}
