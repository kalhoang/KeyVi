// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Typed LogEvent rendering (PLT-R902): every case maps to a stable code, a category and metadata fields.

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

/// One value of every `LogEvent` case and sub-case, with the code each must render to.
enum LogEventCatalog {
    static let bundle = BundleKey(rawValue: "com.example.Editor")!
    static let rule = RuleID(rawValue: "editor.default")!
    static let salt = RedactionSalt(bytes: Array(repeating: 9, count: 32))

    /// `metadataText` fills every free String the event types still carry (bundle metadata, appcast build).
    static func all(metadataText: String = "1.0") -> [(LogEvent, String)] {
        let identity = AppIdentity(
            displayName: metadataText, slug: metadataText, bundleIdentifier: metadataText, version: metadataText,
            build: metadataText, channel: .stable)
        return [
            (.lifecycle(.launched(identity)), "lifecycle.launched"),
            (.lifecycle(.safeModeEntered(recentCrashes: 3)), "lifecycle.safeModeEntered"),
            (.lifecycle(.terminating), "lifecycle.terminating"), (.lifecycle(.tapCreated), "lifecycle.tapCreated"),
            (.lifecycle(.tapRemoved), "lifecycle.tapRemoved"),
            (.health(HealthEvent(kind: .flush, at: DiagnosticsFixtures.generatedAt, bundle: bundle)), "health.flush"),
            (.hostState(from: .starting, to: .paused(.secureInput)), "host.state"),
            (.permission(.accessibility, .granted), "permission.state"),
            (.settings(.loaded(schemaVersion: 2, migratedFrom: 1)), "settings.loaded"),
            (.settings(.loaded(schemaVersion: 2, migratedFrom: nil)), "settings.loaded"),
            (.settings(.recoveredFromBackup(file: .macros)), "settings.recoveredFromBackup"),
            (.settings(.corruptFileQuarantined(file: .appModes)), "settings.corruptFileQuarantined"),
            (.settings(.newerSchemaReadOnly(file: .settings, schemaVersion: 9)), "settings.newerSchemaReadOnly"),
            (.settings(.writeFailed(file: .ruleOverrides, errno: 28)), "settings.writeFailed"),
            (.settings(.imported(macros: 4, appEntries: 2, overrides: 1)), "settings.imported"),
            (.settings(.exported), "settings.exported"),
            (.rules(.loaded(rules: 40, overrides: 2)), "rules.loaded"),
            (.rules(.invalidShippedFileUsingEmbeddedDefaults), "rules.invalidShippedFileUsingEmbeddedDefaults"),
            (.rules(.tie(winner: rule, loser: RuleID(rawValue: "editor.other")!)), "rules.tie"),
            (.rules(.resolved(bundle: bundle, rule: rule, strategy: .paste, source: .shipped)), "rules.resolved"),
            (
                .rules(.resolved(bundle: bundle, rule: nil, strategy: .backspaceReplace, source: .default)),
                "rules.resolved"
            ),
            (.update(.checkStarted(manual: true)), "update.checkStarted"),
            (.update(.updateFound(build: metadataText)), "update.updateFound"),
            (.update(.installScheduledOnQuit), "update.installScheduledOnQuit"),
            (.update(.failed(code: -1)), "update.failed"),
            (.note("tap re-created", category: .tap), "note"),
            (
                .redacted("unexpected role", Redacted.hashed(metadataText, salt: salt), category: .focus),
                "note.redacted"
            ),
        ]
    }
}

@Suite struct LogEventRenderingTests {
    @Test func everyCaseHasItsStableCode() {
        for (event, code) in LogEventCatalog.all() {
            #expect(LogRecord(event: event, level: .info, at: DiagnosticsFixtures.generatedAt).code == code)
        }
    }

    @Test func fieldsCarryTypedMetadata() {
        let resolved = LogRecord(
            event: .rules(
                .resolved(bundle: LogEventCatalog.bundle, rule: LogEventCatalog.rule, strategy: .paste, source: .user)),
            level: .notice, at: .distantPast)
        #expect(resolved.category == .rules)
        #expect(resolved.fields["bundle"] == .string("com.example.Editor"))
        #expect(resolved.fields["rule"] == .string("editor.default"))
        #expect(resolved.fields["strategy"] == .string("paste"))
        #expect(resolved.fields["source"] == .string("user"))
        let state = LogRecord(
            event: .hostState(from: .readyEnglish, to: .failOpen(.watchdog)), level: .error, at: .distantPast)
        #expect(state.fields["to"] == .string("failOpen.watchdog"))
        let loaded = LogRecord(
            event: .settings(.loaded(schemaVersion: 2, migratedFrom: 1)), level: .info, at: .distantPast)
        #expect(loaded.fields["migratedFrom"]?.intValue == 1)
    }

    @Test func launchKeepsBundleMetadataButNotTheDisplayName() {
        let identity = DiagnosticsFixtures.identity
        let record = LogRecord(event: .lifecycle(.launched(identity)), level: .notice, at: .distantPast)
        #expect(record.fields["bundleId"] == .string(identity.bundleIdentifier))
        #expect(record.fields["version"] == .string("0.1.0"))
        #expect(record.fields["displayName"] == nil)
    }

    @Test func freeTextInMetadataFieldsIsDropped() {
        let record = LogRecord(
            event: .update(.updateFound(build: "build 7\nnext line")), level: .info, at: .distantPast)
        #expect(record.fields["build"] == .string("<dropped>"))
    }

    @Test func healthEventsGetCategoryLevelAndDetailFields() {
        let event = HealthEvent(
            kind: .permissionTransition, at: DiagnosticsFixtures.generatedAt,
            detail: .permission(.accessibility, from: .granted, to: .denied))
        let record = LogRecord(event: .health(event), level: event.kind.logLevel, at: .distantPast)
        #expect(record.category == .permissions)
        #expect(record.fields["from"] == .string("granted"))
        #expect(record.fields["eventAt"] == .string("2027-01-15T08:00:00Z"))
        #expect(HealthEvent.Kind.tapTimeout.logLevel == .error)
        #expect(HealthEvent.Kind.flush.logLevel == .notice)
        for kind in HealthEvent.Kind.allCases {
            #expect(
                LogRecord(event: .health(HealthEvent(kind: kind, at: .distantPast)), level: .info, at: .distantPast)
                    .code == "health." + kind.rawValue)
        }
    }

    @Test func healthDetailsRenderAsPairs() {
        let at = DiagnosticsFixtures.generatedAt
        let details: [(HealthEvent.Detail, String)] = [
            (.count(3), "count=3"), (.durationMicroseconds(250), "durationUs=250"),
            (.fallback(from: .axReplace, to: .paste), "fromStrategy=axReplace toStrategy=paste"),
            (
                .secureInput(holder: LogEventCatalog.bundle, holderKind: .application, durationMilliseconds: 9),
                "holder=com.example.Editor holderKind=application durationMs=9"
            ),
            (.failOpen(.postingBroken), "failOpen=postingBroken"),
        ]
        for (detail, expected) in details {
            #expect(
                HealthEvent(kind: .flush, at: at, detail: detail).summaryLine == "2027-01-15T08:00:00Z flush "
                    + expected)
        }
    }

    @Test func levelsMapToUnifiedLogTypes() {
        #expect(LogLevel.debug.osLogType == .debug)
        #expect(LogLevel.info.osLogType == .info)
        #expect(LogLevel.notice.osLogType == .default)
        #expect(LogLevel.error.osLogType == .error)
        #expect(LogLevel.fault.osLogType == .fault)
        #expect(LogLevel.debug < LogLevel.fault)
    }
}
