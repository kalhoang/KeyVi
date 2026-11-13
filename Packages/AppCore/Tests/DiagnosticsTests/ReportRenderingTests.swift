// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Plain text (PLT-R1204), JSON attachment (PRD-R47) and the override rule JSON (PLT-R541, ADR 0312).

import AppModel
import Foundation
import Testing

@testable import Diagnostics
@testable import TestSupport

@Suite struct PlainTextReportTests {
    @Test func vietnameseReportUsesVietnameseLabels() {
        let text = DiagnosticsRenderer.plainText(DiagnosticsFixtures.representativeReport(), language: .vietnamese)
        #expect(text.hasPrefix("Báo cáo chẩn đoán\nTạo lúc: 2027-01-15T08:00:00Z\n"))
        #expect(text.contains("[Quyền]\n  Trợ năng: granted"))
        #expect(text.contains("  Số mục gõ tắt: 12"))
        #expect(text.contains("  Triệu chứng: Lặp chữ"))
        #expect(text.contains("  Sửa được: có"))
        #expect(text.contains("  Trường không đưa vào báo cáo: web.urlPrefixes"))
        #expect(text.contains("  T1: p50 33 µs, p99 33 µs (100 mẫu)"))
    }

    @Test func englishReportUsesEnglishLabels() {
        let text = DiagnosticsRenderer.plainText(DiagnosticsFixtures.representativeReport(), language: .english)
        #expect(text.hasPrefix("Diagnostics report\n"))
        #expect(text.contains("  Symptom: Duplicated letters"))
        #expect(text.contains("  Editable: yes"))
        #expect(text.contains("  \"id\" : \"user.browser.1\""))
        #expect(text.contains("  normal: T2 p50 900 µs, p99 1300 µs; T4 p50 4000 µs, p99 7500 µs (200 samples)"))
        #expect(text.contains("  2027-01-15T07:50:00Z fallbackActivated bundle=com.example.Browser"))
    }

    @Test func emptySectionsSayNoneOrUnknown() {
        let text = DiagnosticsRenderer.plainText(DiagnosticsFixtures.minimalReport(), language: .english)
        #expect(!text.contains("[Focused field]"))
        #expect(!text.contains("[Compatibility rule]"))
        #expect(!text.contains("[Problem report]"))
        #expect(text.contains("  Keyboard layout: unknown"))
        #expect(text.contains("  Enabled input sources: none"))
        #expect(text.contains("  T1: none (0 samples)"))
        #expect(text.contains("[Recent events]\n  none"))
        #expect(text.contains("[Possibly conflicting input apps]\n  none"))
    }

    @Test func everySymptomHasALabelInBothLanguages() {
        for language in InterfaceLanguage.allCases {
            let labels = ReportLabels.labels(for: language)
            for symptom in DiagnosticsReport.Symptom.allCases { #expect(labels.symptoms[symptom] != nil) }
        }
    }
}

@Suite struct ReportJSONTests {
    @Test func jsonDecodesBackToTheSameReport() throws {
        for report in [DiagnosticsFixtures.representativeReport(), DiagnosticsFixtures.minimalReport()] {
            let data = try DiagnosticsRenderer.json(report)
            #expect(try ReportJSON.decoder().decode(DiagnosticsReport.self, from: data) == report)
        }
    }

    @Test func overrideRendersInTheRulesFileShape() throws {
        let userOverride = try #require(DiagnosticsFixtures.representativeRule().userOverride)
        let text = DiagnosticsRenderer.ruleJSON(userOverride, pretty: false)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "match", "action"])
        let match = try #require(object["match"] as? [String: Any])
        #expect(match["bundleIds"] as? [String] == ["com.example.Browser"])
        #expect((match["ax"] as? [String: Any])?["roles"] as? [String] == ["AXTextField"])
        #expect(match["web"] == nil)
        #expect(match["titlePattern"] == nil)
        let action = try #require(object["action"] as? [String: Any])
        #expect(action["strategy"] as? String == "backspaceReplace")
        #expect(action["fallback"] as? [String] == ["selectReplace"])
        #expect((action["params"] as? [String: Any])?["inlineCompletion"] as? String == "axSelectionThenPlaceholder")
        #expect(!text.contains("\n"))
        #expect(DiagnosticsRenderer.ruleJSON(userOverride, pretty: true).contains("\n"))
    }

    @Test func overrideWithoutAXFieldsHasNoAXObject() throws {
        let bare = DiagnosticsReport.ReportedOverride(
            id: RuleID(rawValue: "user.x")!,
            match: .init(engines: [.electron], appVersion: VersionRange(min: LooseVersion("1.2"))),
            strategy: .paste, parameters: nil, fallback: nil, requireTextFocus: nil, verifyReentry: .whenReadable,
            engineContext: .code, omittedMatchFields: [])
        let text = DiagnosticsRenderer.ruleJSON(bare, pretty: false)
        #expect(
            text
                == "{\"action\":{\"engineContext\":\"code\",\"strategy\":\"paste\",\"verifyReentry\":\"whenReadable\"},\"id\":\"user.x\",\"match\":{\"appVersion\":{\"min\":\"1.2\"},\"engines\":[\"electron\"]}}"
        )
    }
}
