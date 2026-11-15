// SPDX-License-Identifier: GPL-3.0-or-later
//
// Health notices (PLT-R397B, PLT-R1201 "a plain explanation", PRD-R62): a secure-input bursts event of the last 24
// hours is explained with a label and a sentence in the interface language, with the app name as an argument, in the
// plain-text report the Diagnostics window shows and in the copied block, as a `#` line parsers ignore (ADR 0501 rule
// 2).

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct HealthNoticeTests {
    static let viExplanation =
        "Có ứng dụng liên tục bật rồi tắt chế độ nhập bảo mật (Secure Input) trong lúc bạn gõ, nên vài phím có thể "
        + "không tới được Sample App. Hãy thử thoát các bộ gõ khác, trình quản lý mật khẩu hoặc ứng dụng chạy nền mới "
        + "cài để tìm ra ứng dụng đó."
    static let enExplanation =
        "An app keeps turning Secure Input on and off while you type, so some keys may not reach Sample App. Try "
        + "quitting other input methods, password managers or recently installed background apps to find it."

    static func report(
        _ events: [HealthEvent], language: InterfaceLanguage = .vietnamese
    ) -> DiagnosticsReport {
        var report = DiagnosticsFixtures.representativeReport()
        report.healthEvents = events
        report.settings.interfaceLanguage = language
        return report
    }

    static func bursts(hoursAgo: Double) -> HealthEvent {
        HealthEvent(
            kind: .secureInputBursts, at: DiagnosticsFixtures.generatedAt.addingTimeInterval(-hoursAgo * 3_600),
            detail: .count(3))
    }

    @Test func aRecentBurstsEventCallsForItsNotice() {
        let report = Self.report([Self.bursts(hoursAgo: 23), Self.bursts(hoursAgo: 1)])
        #expect(HealthNotice.notices(in: report) == [.secureInputBursts])
    }

    @Test func olderEventsAndOtherKindsCallForNone() {
        #expect(HealthNotice.notices(in: Self.report([Self.bursts(hoursAgo: 25)])).isEmpty)
        #expect(HealthNotice.notices(in: DiagnosticsFixtures.representativeReport()).isEmpty)
        for kind in HealthEvent.Kind.allCases where kind != .secureInputBursts {
            #expect(HealthNotice(kind: kind) == nil, "\(kind)")
        }
    }

    @Test func theCopyIsTheDraftInBothLanguages() {
        let vi = DiagnosticsRenderer.healthNoticeText(.secureInputBursts, language: .vietnamese, appName: "Sample App")
        #expect(vi.label == "Chế độ nhập bảo mật bật tắt liên tục")
        #expect(vi.explanation == Self.viExplanation)
        let en = DiagnosticsRenderer.healthNoticeText(.secureInputBursts, language: .english, appName: "Sample App")
        #expect(en.label == "Secure Input keeps turning on and off")
        #expect(en.explanation == Self.enExplanation)
        for text in [vi.label, vi.explanation, en.label, en.explanation] {
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}") && !text.lowercased().contains("tệp"))
        }
    }

    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func thePlainTextExplainsTheBurstsUnderTheEvents(_ language: InterfaceLanguage) {
        let event = Self.bursts(hoursAgo: 1)
        let text = DiagnosticsRenderer.plainText(Self.report([event], language: language), language: language)
        let notice = DiagnosticsRenderer.healthNoticeText(
            .secureInputBursts, language: language, appName: DiagnosticsFixtures.identity.displayName)
        #expect(text.contains("  " + event.summaryLine + "\n  " + notice.label + ": " + notice.explanation + "\n"))
        let quiet = DiagnosticsRenderer.plainText(Self.report([Self.bursts(hoursAgo: 30)]), language: language)
        #expect(!quiet.contains(notice.explanation))
    }

    @Test(arguments: [InterfaceLanguage.vietnamese, .english])
    func theCopiedBlockCarriesTheNoticeAsAComment(_ language: InterfaceLanguage) throws {
        let report = Self.report([Self.bursts(hoursAgo: 1)], language: language)
        let block = DiagnosticsRenderer.issueBlock(report)
        let notice = DiagnosticsRenderer.healthNoticeText(
            .secureInputBursts, language: language, appName: DiagnosticsFixtures.identity.displayName)
        let lines = block.split(separator: "\n").map(String.init)
        let comment = "# " + notice.label + ": " + notice.explanation
        #expect(lines.dropLast().last == comment, "the notice closes the block, after the events")
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(block))
        #expect(parsed["health.events"] == "1")
        #expect(!parsed.values.contains { $0.contains(notice.explanation) })
        #expect(!block.contains("\u{2014}") && !block.contains("\u{2013}"))
    }

    @Test func theBlockStaysWithinTwoHundredLinesWithANotice() {
        var events = (0..<500).map {
            HealthEvent(kind: .flush, at: DiagnosticsFixtures.generatedAt.addingTimeInterval(-Double(600 - $0)))
        }
        events.append(Self.bursts(hoursAgo: 0))
        let lines = DiagnosticsRenderer.issueBlock(Self.report(events)).split(
            separator: "\n", omittingEmptySubsequences: false
        ).dropLast()
        #expect(lines.count == IssueBlock.maximumLines)
        #expect(lines.last == "```")
        #expect(lines.dropLast().last?.hasPrefix("# ") == true)
        #expect(lines.dropLast(2).last?.contains("secureInputBursts") == true, "the newest event is kept")
    }
}
