// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R901, PLT-R914: diagnostics show the learned collision memory as an entry count only, never a word; a report
// built without it says nothing about it (the JSON keeps its old shape).

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

    @Test func theJSONCarriesTheCountWhenSet() throws {
        var report = DiagnosticsFixtures.representativeReport()
        let without = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!without.contains("learnedCollisionEntries"))
        report.settings.learnedCollisionEntries = 3
        let decoded = try JSONDecoder().decode(DiagnosticsReport.self, from: try JSONEncoder().encode(report))
        #expect(decoded.settings.learnedCollisionEntries == 3)
    }
}
