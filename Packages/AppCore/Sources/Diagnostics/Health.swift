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
            settingsRecovered, settingsNewerSchema, safeModeEntered,
            /// PLT-R397B: short secure-input episodes keep ending while the user types (`.count`).
            secureInputBursts,
            /// PLT-R330 step 6: the system kept disabling the tap, so it was removed (fail open) instead of
            /// re-enabled again (`.failOpen` detail).
            tapUnstable,
            /// PLT-R330 step 1 (amended 19/11/2026): the tap was enabled again after a system disable, once the live
            /// permission check answered (`.tapRecovery` detail: how long keys bypassed the tap).
            tapRecovered
    }

    public enum Detail: Sendable, Hashable, Codable {
        case count(Int)
        case durationMicroseconds(UInt64)
        case permission(PermissionKind, from: PermissionState, to: PermissionState)
        case fallback(from: InjectionStrategy, to: InjectionStrategy)
        case secureInput(holder: BundleKey?, holderKind: SecureInputHolder.Kind?, durationMilliseconds: UInt64)
        case failOpen(FailOpenReason)
        /// Whole milliseconds from the disabled event, as the tap saw it, to the re-enable (`tapRecovered`).
        case tapRecovery(milliseconds: UInt64)
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

/// PLT-R397B thresholds. An episode shorter than `shortEpisode` that key evidence ended (PLT-R398B) happened while the
/// user was typing: the 2 s poll (PLT-R395) saw it start less than a second before the next key reached the tap. A
/// password typed into a secure field lasts longer, and an episode a poll ends lasts about a poll interval. In the
/// product owner's trace of 14/11/2026 a background process produced three such episodes within 40 s. `threshold`
/// of them ending within `window` record one `secureInputBursts` event; the next can follow one `window` later.
public enum SecureInputBursts {
    public static let shortEpisode: TimeInterval = 1
    public static let threshold = 3
    public static let window: TimeInterval = 600
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
        /// Key evidence ended it (PLT-R398B): the user was typing.
        var endedByKey = false
    }

    /// Ends of short episodes that typing ended, and the last burst event (PLT-R397B).
    private struct Bursts {
        var ends: [Date] = []
        var reportedAt: Date?
    }

    private let capacity: Int
    private let ring = Mutex(Ring())
    private let episode = Mutex<Episode?>(nil)
    private let bursts = Mutex(Bursts())
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
        let seconds = max(0, now.timeIntervalSince(ended.start))
        record(
            HealthEvent(
                kind: .secureInputEpisode, at: now,
                detail: .secureInput(
                    holder: ended.holder, holderKind: ended.holderKind,
                    durationMilliseconds: UInt64((seconds * 1_000).rounded()))))
        if ended.endedByKey && seconds < SecureInputBursts.shortEpisode { noteShortEpisode(endedAt: now) }
    }

    /// PLT-R398B: the tap processed a key while paused for secure input; the episode in progress ended while the
    /// user typed. Called before the host state change that ends it.
    public func noteSecureInputEndedByKey() {
        episode.withLock { $0?.endedByKey = true }
    }

    /// PLT-R397B: `SecureInputBursts.threshold` short episodes that typing ended, within `window`, record one
    /// content-free `secureInputBursts` event (no holder: PLT-R396 names whatever app was frontmost).
    private func noteShortEpisode(endedAt now: Date) {
        let count: Int? = bursts.withLock { state in
            state.ends.removeAll { now.timeIntervalSince($0) > SecureInputBursts.window }
            state.ends.append(now)
            if let last = state.reportedAt, now.timeIntervalSince(last) < SecureInputBursts.window { return nil }
            guard state.ends.count >= SecureInputBursts.threshold else { return nil }
            state.reportedAt = now
            let count = state.ends.count
            state.ends.removeAll()
            return count
        }
        if let count { record(HealthEvent(kind: .secureInputBursts, at: now, detail: .count(count))) }
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
