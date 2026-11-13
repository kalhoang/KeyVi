// SPDX-License-Identifier: LicenseRef-App-Pending
//
// W1-A acceptance canary (PLT-R901, PLT-R1203, PRD-R45, ADR 0312): logging every LogEvent case with
// canary-shaped metadata, a full report in every output and the issue block never contain the canary.

import AppModel
import CompatRules
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

private enum Canary {
    /// Shaped like typed content: Vietnamese letters, spaces, a distinctive marker.
    static let text = "đá canary KAL7731 gõ thử"
    static let marker = "KAL7731"
    static let url = "https://canary.example/KAL7731/đá canary"

    static func assertAbsent(_ output: String, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!output.contains(marker), "\(what) contains the canary", sourceLocation: sourceLocation)
        #expect(!output.contains("canary.example"), "\(what) contains the canary URL", sourceLocation: sourceLocation)
        #expect(!output.contains("gõ thử"), "\(what) contains canary words", sourceLocation: sourceLocation)
    }
}

@Suite struct CanaryTests {
    @Test func loggingEveryEventWithCanaryMetadataNeverWritesTheCanary() {
        let clock = FixedWallClock(DiagnosticsFixtures.generatedAt)
        let fileSystem = InMemoryFileSystem(now: { clock.now() })
        let directory = URL(fileURLWithPath: "/logs/canary")
        let logger = DiagnosticsLogger(
            policy: LogStorePolicy(directory: directory), fileSystem: fileSystem, clock: clock, subsystem: "test.canary"
        )
        let events =
            LogEventCatalog.all(metadataText: Canary.text) + LogEventCatalog.all(metadataText: Canary.marker + " x")
        for (event, _) in events {
            logger.log(event, level: .info)
            let record = LogRecord(event: event, level: .info, at: clock.now())
            Canary.assertAbsent(UnifiedLogMirror.fieldsText(record.fields) + record.code, "unified log message")
        }
        let health = HealthEventLog(mirror: logger)
        for event in DiagnosticsFixtures.representativeHealthEvents() { health.record(event) }
        logger.flush()
        let written = fileSystem.nodes.values.compactMap(\.data).map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(written.split(separator: "\n").count == events.count + 3)
        Canary.assertAbsent(written, "log file")
    }

    @Test func reportFromACanaryOverrideNeverContainsTheCanary() throws {
        let rule = Rule(
            id: RuleID(rawValue: "user.canary.1")!, summary: Canary.text,
            match: RuleMatch(
                bundleIds: [DiagnosticsFixtures.reportedBundle], ax: AXMatch(roles: ["AXTextField"]),
                web: WebMatch(urlPrefixes: [Canary.url]), titlePattern: Canary.text),
            action: RuleAction(strategy: .selectReplace, params: StrategyParams(interEventDelayUs: 2_000)),
            provenance: nil)
        let projected = Self.reportedOverride(from: rule)
        #expect(projected.omittedMatchFields == [.webURLPrefixes, .titlePattern])
        var report = DiagnosticsFixtures.representativeReport()
        report.rule?.userOverride = projected
        let outputs: [(String, String)] = [
            (DiagnosticsRenderer.plainText(report, language: .vietnamese), "plain text (vi)"),
            (DiagnosticsRenderer.plainText(report, language: .english), "plain text (en)"),
            (String(decoding: try DiagnosticsRenderer.json(report), as: UTF8.self), "JSON"),
            (DiagnosticsRenderer.issueBlock(report), "issue block"),
            (DiagnosticsRenderer.ruleJSON(projected, pretty: true), "rule JSON"),
        ]
        for (output, what) in outputs { Canary.assertAbsent(output, what) }
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(DiagnosticsRenderer.issueBlock(report)))
        #expect(parsed["rule.userOverrideOmitted"] == "web.urlPrefixes,titlePattern")
        #expect(parsed["rule.userOverride"]?.contains("\"strategy\":\"selectReplace\"") == true)
    }

    /// Stand-in for ShellCore's `ReportAssembler.reportedOverride(from:)` (W1-G owns the real projection and its
    /// own canary test): metadata match fields are copied, summary, provenance, URL prefixes and title pattern
    /// are not (ADR 0312).
    private static func reportedOverride(from rule: Rule) -> DiagnosticsReport.ReportedOverride {
        let match = rule.match
        let params = rule.action.params.map {
            DiagnosticsReport.ReportedParameters(
                unicodeChunk: $0.unicodeChunk, interEventDelayUs: $0.interEventDelayUs,
                postDeleteSettleUs: $0.postDeleteSettleUs, firstEditDelayUs: $0.firstEditDelayUs,
                inlineCompletion: $0.inlineCompletion, allowMultiCharEvents: $0.allowMultiCharEvents,
                allowSplit: $0.allowSplit, longTextThreshold: $0.longTextThreshold, restoreDelayMs: $0.restoreDelayMs,
                verifyAfterEdit: $0.verifyAfterEdit)
        }
        var omitted: [DiagnosticsReport.OmittedMatchField] = []
        if match.web?.urlPrefixes != nil { omitted.append(.webURLPrefixes) }
        if match.titlePattern != nil { omitted.append(.titlePattern) }
        return DiagnosticsReport.ReportedOverride(
            id: rule.id,
            match: .init(
                bundleIds: match.bundleIds, bundleGroup: match.bundleGroup, engines: match.engines,
                appCategories: match.appCategories, appVersion: match.appVersion, macOS: match.macOS,
                axRoles: match.ax?.roles, axSubroles: match.ax?.subroles, axIdentifiers: match.ax?.identifiers,
                axDomClasses: match.ax?.domClasses, axAncestorRoles: match.ax?.ancestorRoles,
                axEditable: match.ax?.editable),
            strategy: rule.action.strategy, parameters: params, fallback: rule.action.fallback,
            requireTextFocus: rule.action.requireTextFocus, verifyReentry: rule.action.verifyReentry,
            engineContext: rule.action.engineContext, omittedMatchFields: omitted)
    }
}
