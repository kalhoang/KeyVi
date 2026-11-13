// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import Foundation
internal import RealtimeSupport

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
/// Implemented in the skeleton (docs/decisions/0313-testability-seams.md); W1-A adds the log-file mirror.
public final class HealthEventLog: Sendable {
    /// The report lists the last 50 health events (PLT-R1202).
    public static let reportedEventCount = 50
    /// Events kept in memory, and read back from earlier sessions' logs, for the report's 24-hour counters.
    public static let defaultCapacity = 256

    private struct Ring {
        var events: [HealthEvent] = []
        var next = 0
    }

    /// The secure-input episode in progress (PLT-R1206).
    private struct Episode {
        var holder: BundleKey?
        var holderKind: SecureInputHolder.Kind?
        var start: Date
    }

    private let capacity: Int
    private let ring = Mutex(Ring())
    private let episode = Mutex<Episode?>(nil)
    private let mirror: (any DiagnosticsLogging)?

    /// `mirror` (production: the `DiagnosticsLogger`) receives every recorded event as `.health`, at error
    /// level for events that lose or risk losing keys and notice level otherwise (PRD-R46, PLT-R1206).
    public init(capacity: Int = HealthEventLog.defaultCapacity, mirror: (any DiagnosticsLogging)? = nil) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.mirror = mirror
    }

    public func record(_ event: HealthEvent) {
        ring.withLock { ring in
            if ring.events.count < capacity {
                ring.events.append(event)
            } else {
                ring.events[ring.next] = event
            }
            ring.next = (ring.next + 1) % capacity
        }
        mirror?.log(.health(event), level: event.kind.logLevel)
    }

    /// Secure-input episodes (PLT-R1206): `active` with the likely holder starts an episode; the end of it, or a
    /// different holder, records one `secureInputEpisode` event with the holder's bundle ID and kind and the
    /// duration in milliseconds (never negative when the wall clock was set back). The holder's name is never
    /// recorded (PLT-R901).
    public func noteSecureInput(_ holder: SecureInputHolder?, active: Bool, at now: Date) {
        let ended: Episode? = episode.withLock { current in
            let next = active ? Episode(holder: holder?.bundle, holderKind: holder?.kind, start: now) : nil
            if let running = current, let next, running.holder == next.holder, running.holderKind == next.holderKind {
                return nil
            }
            let previous = current
            current = next
            return previous
        }
        guard let ended else { return }
        let milliseconds = max(0, now.timeIntervalSince(ended.start)) * 1_000
        record(
            HealthEvent(
                kind: .secureInputEpisode, at: now,
                detail: .secureInput(
                    holder: ended.holder, holderKind: ended.holderKind,
                    durationMilliseconds: UInt64(milliseconds.rounded()))))
    }

    /// Newest last, at most `limit` events.
    public func recent(limit: Int) -> [HealthEvent] {
        ring.withLock { ring in
            let ordered =
                ring.events.count < capacity
                ? ring.events : Array(ring.events[ring.next...] + ring.events[..<ring.next])
            return Array(ordered.suffix(max(0, limit)))
        }
    }

    /// The events a report is assembled from (PLT-R1202, PRD-R46): the earlier sessions' events (`earlier`, asked
    /// for at most this ring's capacity) then this session's, newest last. The report lists the last 50 of them;
    /// its 24-hour tap counters see all of them, so many later events do not hide a recent tap timeout.
    public func reportSource(earlier: (Int) -> [HealthEvent]) -> [HealthEvent] {
        HealthEvent.reportList(earlier: earlier(capacity), current: recent(limit: capacity), limit: 2 * capacity)
    }

    /// Count of events of `kind` within `window` before `now` (PLT-R330 "more than 3 within 10 minutes").
    public func count(of kind: HealthEvent.Kind, within window: TimeInterval, now: Date) -> Int {
        let start = now.addingTimeInterval(-window)
        return ring.withLock { ring in
            ring.events.reduce(0) { $0 + ($1.kind == kind && $1.at >= start && $1.at <= now ? 1 : 0) }
        }
    }
}
