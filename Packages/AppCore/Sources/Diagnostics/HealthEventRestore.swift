// SPDX-License-Identifier: GPL-3.0-or-later
//
// Health events of earlier sessions (PRD-R46): the log keeps every event as a `health.<kind>` record with the
// metadata fields of `HealthEvent.logFields`, so a crash or a tap timeout from before this launch can be read
// back and listed in the report's last 50 events (PLT-R1202). Metadata only (PLT-R1206).

internal import AppModel
internal import Foundation

extension HealthEvent {
    static let recordCodePrefix = "health."

    /// The event a `health.<kind>` log record was written from, or nil for other records, unknown kinds and
    /// records without a readable time. A detail field that does not parse leaves the detail empty.
    public init?(record: LogRecord) {
        guard record.code.hasPrefix(Self.recordCodePrefix),
            let kind = Kind(rawValue: String(record.code.dropFirst(Self.recordCodePrefix.count)))
        else { return nil }
        let fields = record.fields.compactMapValues(\.stringValue)
        guard let at = fields["eventAt"].flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
        self.init(
            kind: kind, at: at, bundle: fields["bundle"].flatMap(BundleKey.init(rawValue:)),
            rule: fields["rule"].flatMap(RuleID.init(rawValue:)), detail: Self.detail(fields))
    }

    /// The inverse of the detail part of `detailPairs`.
    private static func detail(_ fields: [String: String]) -> Detail? {
        if let count = fields["count"] { return Int(count).map(Detail.count) }
        if let duration = fields["durationUs"] { return UInt64(duration).map(Detail.durationMicroseconds) }
        if let recovery = fields["recoveryMs"] { return UInt64(recovery).map(Detail.tapRecovery(milliseconds:)) }
        if let permission = fields["permission"] {
            guard let kind = PermissionKind(rawValue: permission),
                let from = fields["from"].flatMap(PermissionState.init(rawValue:)),
                let to = fields["to"].flatMap(PermissionState.init(rawValue:))
            else { return nil }
            return .permission(kind, from: from, to: to)
        }
        if let from = fields["fromStrategy"] {
            guard let from = InjectionStrategy(rawValue: from),
                let to = fields["toStrategy"].flatMap(InjectionStrategy.init(rawValue:))
            else { return nil }
            return .fallback(from: from, to: to)
        }
        if let duration = fields["durationMs"] {
            guard let milliseconds = UInt64(duration) else { return nil }
            return .secureInput(
                holder: fields["holder"].flatMap(BundleKey.init(rawValue:)),
                holderKind: fields["holderKind"].flatMap(SecureInputHolder.Kind.init(rawValue:)),
                durationMilliseconds: milliseconds)
        }
        return fields["failOpen"].flatMap(FailOpenReason.init(rawValue:)).map(Detail.failOpen)
    }

    /// The report's health events (PLT-R1202 "last 50 health events", PRD-R46): earlier sessions' events read
    /// from the log, then this session's from memory, newest last, at most `limit`. An earlier event that is
    /// also among the current ones (the wall clock was set back) is listed once.
    public static func reportList(earlier: [HealthEvent], current: [HealthEvent], limit: Int) -> [HealthEvent] {
        let currentLines = Set(current.map(\.summaryLine))
        let previous = earlier.filter { !currentLines.contains($0.summaryLine) }
        return Array((previous + current).suffix(max(0, limit)))
    }
}
