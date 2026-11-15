// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R901, PLT-R914: diagnostics show the learned collision memory as an entry count only, never a word; a report
// built without it says nothing about it in the JSON and the plain text, and leaves the block key empty. D28 and D29
// (`learnCollisionChoices`, `lookaheadRevision`) are reported with the other settings booleans, in the JSON, the
// plain text and the copied block (ADR 0501, keys added within v1).

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct LearnedCollisionEntriesReportTests {
    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func thePlainTextShowsTheCountOnly(_ language: InterfaceLanguage) {
        let labels = ReportLabels.labels(for: language)
        var report = DiagnosticsFixtures.representativeReport()
        #expect(!DiagnosticsRenderer.plainText(report, language: language).contains(labels.learnedCollisionEntries))
        report.settings.learnedCollisionEntries = 37
        let text = DiagnosticsRenderer.plainText(report, language: language)
        #expect(text.contains("\n  " + labels.learnedCollisionEntries + ": 37\n"))
    }

    /// ADR 0501: `settings.learnCollisionChoices`, `settings.learnedCollisionEntries` (a count, empty when the report
    /// was built without it) and `settings.lookaheadRevision` follow `settings.restoreHotkey`.
    @Test func theCopiedBlockCarriesD28D29AndTheCountOnly() throws {
        var report = DiagnosticsFixtures.representativeReport()
        report.settings.learnCollisionChoices = false
        let without = DiagnosticsRenderer.issueBlock(report)
        #expect(
            without.contains(
                "\nsettings.restoreHotkey: false\nsettings.learnCollisionChoices: false\n"
                    + "settings.learnedCollisionEntries:\nsettings.lookaheadRevision: true\n"))
        report.settings.learnedCollisionEntries = 37
        report.settings.lookaheadRevision = false
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(DiagnosticsRenderer.issueBlock(report)))
        #expect(parsed["settings.learnedCollisionEntries"] == "37")
        #expect(parsed["settings.lookaheadRevision"] == "false")
        #expect(parsed["settings.learnCollisionChoices"] == "false")
    }

    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func thePlainTextShowsD28AndD29(_ language: InterfaceLanguage) {
        let labels = ReportLabels.labels(for: language)
        var report = DiagnosticsFixtures.representativeReport()
        report.settings.lookaheadRevision = false
        let text = DiagnosticsRenderer.plainText(report, language: language)
        #expect(text.contains("\n  " + labels.learnCollisionChoices + ": " + labels.yes + "\n"))
        #expect(text.contains("\n  " + labels.lookaheadRevision + ": " + labels.no + "\n"))
    }

    @Test func theJSONCarriesD28AndD29() throws {
        var report = DiagnosticsFixtures.representativeReport()
        report.settings.learnCollisionChoices = false
        let decoded = try JSONDecoder().decode(DiagnosticsReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded.settings.learnCollisionChoices == false && decoded.settings.lookaheadRevision)
    }

    @Test func theJSONCarriesTheCountWhenSet() throws {
        var report = DiagnosticsFixtures.representativeReport()
        let without = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!without.contains("learnedCollisionEntries"))
        report.settings.learnedCollisionEntries = 3
        let decoded = try JSONDecoder().decode(DiagnosticsReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded.settings.learnedCollisionEntries == 3)
    }
}
