// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R381 amendment, PLT-R1202: an app the focus tracker took from the frontmost application because Accessibility
// named none is reported as such in the JSON, in the plain-text report the Diagnostics window shows and in the copied
// block as the key `focus.appSource` right after `focus.secure` (ADR 0501, added within v1 under rule 4).

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

    /// ADR 0501: `focus.appSource` is a real key after `focus.secure`, with the values of `AppSource`; the closing
    /// comment line that carried it before the key existed is gone. Empty without a focus section (rule 6).
    @Test func theCopiedBlockCarriesTheSourceAsAKeyAfterFocusSecure() throws {
        let fallback = DiagnosticsRenderer.issueBlock(Self.report(.frontmostApplication))
        #expect(fallback.contains("\nfocus.secure: false\nfocus.appSource: frontmostApplication\n"))
        #expect(!fallback.contains("# focus.appSource"))
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(fallback))
        #expect(parsed["focus.appSource"] == "frontmostApplication")
        let named = try #require(
            DiagnosticsRenderer.parseIssueBlock(DiagnosticsRenderer.issueBlock(Self.report(.accessibility))))
        #expect(named["focus.appSource"] == "accessibility")
        let unfocused = DiagnosticsRenderer.issueBlock(DiagnosticsFixtures.minimalReport())
        #expect(unfocused.contains("\nfocus.secure:\nfocus.appSource:\n"))
    }

    @Test func theJSONKeepsTheSource() throws {
        let report = Self.report(.frontmostApplication)
        let decoded = try ReportJSON.decoder().decode(DiagnosticsReport.self, from: DiagnosticsRenderer.json(report))
        #expect(decoded.focus?.appSource == .frontmostApplication)
        #expect(decoded == report)
    }
}
