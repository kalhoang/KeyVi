// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R381 amendment, PLT-R1202: an app the focus tracker took from the frontmost application because Accessibility
// named none is reported as such in the JSON, in the plain-text report the Diagnostics window shows and, as a `#` line
// parsers ignore (ADR 0501 rule 2, no block key yet), in the copied block.

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct FocusedAppSourceReportTests {
    static func report(_ source: DiagnosticsReport.FocusSection.AppSource) -> DiagnosticsReport {
        var report = DiagnosticsFixtures.representativeReport()
        report.focus?.appSource = source
        return report
    }

    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func thePlainTextSaysWhereTheAppCameFrom(_ language: InterfaceLanguage) {
        let labels = ReportLabels.labels(for: language)
        let fallback = DiagnosticsRenderer.plainText(Self.report(.frontmostApplication), language: language)
        #expect(fallback.contains("\n  " + labels.appSource + ": frontmostApplication\n"))
        let named = DiagnosticsRenderer.plainText(Self.report(.accessibility), language: language)
        #expect(named.contains("\n  " + labels.appSource + ": accessibility\n"))
    }

    /// The block has no key for it yet (ADR 0501 names every key), so a comment line carries it for maintainers.
    @Test func theCopiedBlockMarksTheFallbackWithAComment() throws {
        let fallback = DiagnosticsRenderer.issueBlock(Self.report(.frontmostApplication))
        #expect(fallback.contains("\n# focus.appSource: frontmostApplication\n"))
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(fallback))
        #expect(parsed["focus.appSource"] == nil)
        #expect(!DiagnosticsRenderer.issueBlock(Self.report(.accessibility)).contains("appSource"))
    }

    @Test func theJSONKeepsTheSource() throws {
        let report = Self.report(.frontmostApplication)
        let decoded = try ReportJSON.decoder().decode(DiagnosticsReport.self, from: DiagnosticsRenderer.json(report))
        #expect(decoded.focus?.appSource == .frontmostApplication)
        #expect(decoded == report)
    }
}
