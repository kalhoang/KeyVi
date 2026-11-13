// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The Diagnostics window shows the PLT-R1201 information in the interface language and, next to "Copy report",
// the exact text that button writes (PLT-R1204). Both views come from the same report.

import AppModel
import Diagnostics
import Foundation
import Testing

@testable import ShellCore

@Suite struct ReportDisplayTests {
    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func windowShowsTheLocalizedInformationAndTheExactCopiedText(_ language: InterfaceLanguage) {
        let report = ReportFixtures.report()
        let display = ReportDisplay(report: report, language: language)
        // PLT-R1201, PRD-R62: the information view is the plain-text report in the interface language.
        #expect(display.information == DiagnosticsRenderer.plainText(report, language: language))
        // PLT-R1204: the copy preview is byte for byte what "Copy report" writes.
        let sheet = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand())
        #expect(display.copyPreview == sheet.clipboardText(report))
        #expect(display.copyPreview == ReportPreviewFormat.copiedBlock.text(report))
        #expect(display.information != display.copyPreview)
        #expect(display.histograms == LatencyHistograms.make(report.latency.metrics))
    }

    @Test func theInformationFollowsTheInterfaceLanguage() {
        let report = ReportFixtures.report()
        let vi = ReportDisplay(report: report, language: .vietnamese)
        let en = ReportDisplay(report: report, language: .english)
        #expect(vi.information != en.information)
        #expect(vi.copyPreview == en.copyPreview, "the copied block is the machine format in every language")
    }
}
