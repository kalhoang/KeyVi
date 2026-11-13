// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed `LogEvent` -> stable code and metadata fields (PLT-R902). Every field value is an enumerated raw
// value, a validated identifier (`BundleKey`, `RuleID`), a number, a static literal, a `Redacted` marker or a
// token-checked bundle metadata string. Nothing here can carry typed content (PLT-R901).

public import AppModel
internal import Foundation

struct RenderedLogEvent {
    var category: LogCategory
    var code: String
    var fields: [String: JSONValue]
}

extension LogEvent {
    var rendered: RenderedLogEvent {
        switch self {
        case .lifecycle(let event): Self.render(event)
        case .health(let event):
            RenderedLogEvent(
                category: event.kind.logCategory, code: "health." + event.kind.rawValue, fields: event.logFields)
        case .hostState(let from, let to):
            RenderedLogEvent(
                category: .lifecycle, code: "host.state",
                fields: ["from": .string(from.logCode), "to": .string(to.logCode)])
        case .permission(let kind, let state):
            RenderedLogEvent(
                category: .permissions, code: "permission.state",
                fields: ["permission": .string(kind.rawValue), "state": .string(state.rawValue)])
        case .settings(let event): Self.render(event)
        case .rules(let event): Self.render(event)
        case .update(let event): Self.render(event)
        case .note(let message, let category):
            RenderedLogEvent(category: category, code: "note", fields: ["message": .string(message.description)])
        case .redacted(let message, let value, let category):
            RenderedLogEvent(
                category: category, code: "note.redacted",
                fields: ["message": .string(message.description), "value": .string(value.description)])
        }
    }

    private static func render(_ event: LifecycleEvent) -> RenderedLogEvent {
        switch event {
        case .launched(let identity):
            // The display name is omitted: it may be non-ASCII and the bundle ID identifies the build.
            RenderedLogEvent(
                category: .lifecycle, code: "lifecycle.launched",
                fields: [
                    "slug": .string(MetadataText.logToken(identity.slug)),
                    "bundleId": .string(MetadataText.logToken(identity.bundleIdentifier)),
                    "version": .string(MetadataText.logToken(identity.version)),
                    "build": .string(MetadataText.logToken(identity.build)),
                    "channel": .string(identity.channel.rawValue),
                ])
        case .safeModeEntered(let recentCrashes):
            RenderedLogEvent(
                category: .lifecycle, code: "lifecycle.safeModeEntered",
                fields: ["recentCrashes": .number(Double(recentCrashes))])
        case .terminating: RenderedLogEvent(category: .lifecycle, code: "lifecycle.terminating", fields: [:])
        case .tapCreated: RenderedLogEvent(category: .tap, code: "lifecycle.tapCreated", fields: [:])
        case .tapRemoved: RenderedLogEvent(category: .tap, code: "lifecycle.tapRemoved", fields: [:])
        }
    }

    private static func render(_ event: SettingsEvent) -> RenderedLogEvent {
        let (name, fields): (String, [String: JSONValue]) =
            switch event {
            case .loaded(let schemaVersion, let migratedFrom):
                (
                    "loaded",
                    ["schemaVersion": .number(Double(schemaVersion))].merging(
                        migratedFrom.map { ["migratedFrom": .number(Double($0))] } ?? [:]
                    ) { first, _ in first }
                )
            case .recoveredFromBackup(let file): ("recoveredFromBackup", ["file": .string(file.rawValue)])
            case .corruptFileQuarantined(let file): ("corruptFileQuarantined", ["file": .string(file.rawValue)])
            case .newerSchemaReadOnly(let file, let schemaVersion):
                (
                    "newerSchemaReadOnly",
                    ["file": .string(file.rawValue), "schemaVersion": .number(Double(schemaVersion))]
                )
            case .writeFailed(let file, let errno):
                ("writeFailed", ["file": .string(file.rawValue), "errno": .number(Double(errno))])
            case .imported(let macros, let appEntries, let overrides):
                (
                    "imported",
                    [
                        "macros": .number(Double(macros)), "appEntries": .number(Double(appEntries)),
                        "overrides": .number(Double(overrides)),
                    ]
                )
            case .exported: ("exported", [:])
            }
        return RenderedLogEvent(category: .settings, code: "settings." + name, fields: fields)
    }

    private static func render(_ event: RulesEvent) -> RenderedLogEvent {
        let (name, fields): (String, [String: JSONValue]) =
            switch event {
            case .loaded(let rules, let overrides):
                ("loaded", ["rules": .number(Double(rules)), "overrides": .number(Double(overrides))])
            case .invalidShippedFileUsingEmbeddedDefaults: ("invalidShippedFileUsingEmbeddedDefaults", [:])
            case .tie(let winner, let loser):
                ("tie", ["winner": .string(winner.rawValue), "loser": .string(loser.rawValue)])
            case .resolved(let bundle, let rule, let strategy, let source):
                (
                    "resolved",
                    [
                        "bundle": .string(bundle.rawValue), "rule": rule.map { .string($0.rawValue) } ?? .null,
                        "strategy": .string(strategy.rawValue), "source": .string(source.rawValue),
                    ]
                )
            }
        return RenderedLogEvent(category: .rules, code: "rules." + name, fields: fields)
    }

    private static func render(_ event: UpdateEvent) -> RenderedLogEvent {
        let (name, fields): (String, [String: JSONValue]) =
            switch event {
            case .checkStarted(let manual): ("checkStarted", ["manual": .bool(manual)])
            // The build string comes from the appcast (outside input): only a version-shaped token is kept.
            case .updateFound(let build): ("updateFound", ["build": .string(MetadataText.logToken(build))])
            case .installScheduledOnQuit: ("installScheduledOnQuit", [:])
            case .failed(let code): ("failed", ["code": .number(Double(code))])
            }
        return RenderedLogEvent(category: .updates, code: "update." + name, fields: fields)
    }
}

extension HostStateCode {
    /// Stable dotted spelling for logs and reports, for example `paused.secureInput`.
    var logCode: String {
        switch self {
        case .noPermission: "noPermission"
        case .starting: "starting"
        case .readyVietnamese: "readyVietnamese"
        case .readyEnglish: "readyEnglish"
        case .paused(let reason): "paused." + reason.rawValue
        case .failOpen(let reason): "failOpen." + reason.rawValue
        }
    }
}

extension HealthEvent.Kind {
    var logCategory: LogCategory {
        switch self {
        case .tapTimeout, .tapDisabledByUserInput, .tapReenabled, .watchdogTrip, .flush: .tap
        case .fallbackActivated, .echoLoss, .postingBroken, .placeholderResidue, .pasteRestoreSkipped,
            .generationDiscard:
            .injection
        case .axCircuitBreakerTrip: .focus
        case .permissionTransition: .permissions
        case .secureInputEpisode: .secureInput
        case .ruleLoadError, .ruleTie: .rules
        case .settingsRecovered, .settingsNewerSchema: .settings
        case .safeModeEntered: .lifecycle
        }
    }

    /// Failures that lose or risk losing keys are errors; everything else is a notice.
    var logLevel: LogLevel {
        switch self {
        case .tapTimeout, .watchdogTrip, .postingBroken, .echoLoss, .ruleLoadError, .placeholderResidue,
            .safeModeEntered:
            .error
        default: .notice
        }
    }
}

extension HealthEvent {
    /// Metadata pairs of the event in a fixed order (bundle, rule, detail). Shared by log fields, the issue
    /// block and the plain-text report.
    var detailPairs: [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        if let bundle { pairs.append(("bundle", bundle.rawValue)) }
        if let rule { pairs.append(("rule", rule.rawValue)) }
        switch detail {
        case nil: break
        case .count(let count): pairs.append(("count", String(count)))
        case .durationMicroseconds(let duration): pairs.append(("durationUs", String(duration)))
        case .permission(let kind, let from, let to):
            pairs += [("permission", kind.rawValue), ("from", from.rawValue), ("to", to.rawValue)]
        case .fallback(let from, let to): pairs += [("fromStrategy", from.rawValue), ("toStrategy", to.rawValue)]
        case .secureInput(let holder, let holderKind, let duration):
            if let holder { pairs.append(("holder", holder.rawValue)) }
            if let holderKind { pairs.append(("holderKind", holderKind.rawValue)) }
            pairs.append(("durationMs", String(duration)))
        case .failOpen(let reason): pairs.append(("failOpen", reason.rawValue))
        }
        return pairs
    }

    var logFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["eventAt": .string(at.formatted(.iso8601))]
        for pair in detailPairs { fields[pair.key] = .string(pair.value) }
        return fields
    }

    /// `2026-11-13T09:12:00Z tapTimeout bundle=... count=3`, one line.
    var summaryLine: String {
        ([at.formatted(.iso8601), kind.rawValue] + detailPairs.map { $0.key + "=" + $0.value }).joined(separator: " ")
    }
}
