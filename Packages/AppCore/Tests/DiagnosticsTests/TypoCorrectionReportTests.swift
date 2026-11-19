// SPDX-License-Identifier: GPL-3.0-or-later
//
// D30 and the never-correct list in diagnostics (03-product.md PRD-R80, PRD-R81, PRD-R45; 02-platform.md PLT-R1202;
// spec/01-engine.md ENG-R1121; 1.1.0, ADR 0323): D30 is a non-content setting, the list appears as its entry count
// only, and the host's correction counters as numbers, never a word, in the JSON, the plain text and the copied block
// (ADR 0501, keys added within v1). A report built without them says nothing about them.

import AppModel
import Foundation
import SettingsStore
import Testing

@testable import Diagnostics
@testable import InputHost
@testable import ShellCore
@testable import TestSupport

/// The host side of a report with `corrections` and `correctionUndos` as the host counters read them.
private func host(corrections: UInt64, correctionUndos: UInt64) -> HostReportContext {
    HostReportContext(
        state: .starting, focus: PipelineFixtures.focus(), decision: nil, inputSource: PipelineFixtures.inputSource(),
        enabledSources: [], secureInput: .initial,
        permissions: PermissionStatus(
            accessibility: .granted, postEvent: .granted, listenEvent: .unknown, listenEventRequired: false,
            health: .ready),
        tapEnabled: true, conflicts: [], corrections: corrections, correctionUndos: correctionUndos)
}

@Suite struct ReportSettingsTests {
    /// The plan's acceptance test of Task 26: a report built with `neverCorrect = ["androdi"]`, 3 corrections and 1
    /// undo names the count and the counters and never the word, in every output.
    @Test func d30TheNeverCorrectCountAndTheCountersAppearWithoutWords() throws {
        var user = UserSettings()
        _ = user.neverCorrect("androdi")
        user.typoCorrection = .set(false)
        var report = DiagnosticsFixtures.representativeReport()
        report.settings = ReportSections.settings(SettingsState(user: user))
        report.counters = ReportSections.counters(host(corrections: 3, correctionUndos: 1))
        #expect(report.settings.typoCorrection == false && report.settings.neverCorrectEntries == 1)

        let block = DiagnosticsRenderer.issueBlock(report)
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(block))
        #expect(parsed["settings.typoCorrection"] == "false")
        #expect(parsed["settings.neverCorrectEntries"] == "1")
        #expect(parsed["counters.corrections"] == "3")
        #expect(parsed["counters.correctionUndos"] == "1")
        #expect(block.contains("\nsettings.lookaheadRevision: true\nsettings.typoCorrection: false\n"))

        var outputs = [block, String(decoding: try DiagnosticsRenderer.json(report), as: UTF8.self)]
        for language in [InterfaceLanguage.vietnamese, .english] {
            let labels = ReportLabels.labels(for: language)
            let text = DiagnosticsRenderer.plainText(report, language: language)
            #expect(text.contains("\n  " + labels.typoCorrection + ": " + labels.no + "\n"))
            #expect(text.contains("\n  " + labels.neverCorrectEntries + ": 1\n"))
            #expect(text.contains("\n  " + labels.corrections + ": 3\n"))
            #expect(text.contains("\n  " + labels.correctionUndos + ": 1\n"))
            outputs.append(text)
        }
        for output in outputs { #expect(!output.contains("androdi"), "PRD-R45: the list's words never appear") }
        let decoded = try ReportJSON.decoder().decode(DiagnosticsReport.self, from: DiagnosticsRenderer.json(report))
        #expect(decoded == report)
    }

    /// PRD-R80: D30's copy in the report, the names of the setting in Settings (`Tự sửa từ gõ nhầm`).
    @Test func d30IsLabelledWithTheNameOfTheSetting() {
        #expect(ReportLabels.labels(for: .vietnamese).typoCorrection == "Tự sửa từ gõ nhầm")
        #expect(ReportLabels.labels(for: .english).typoCorrection == "Fix mistyped words")
    }

    /// A report built without the list's count or the counters (the defaults of the section initialisers) leaves the
    /// block keys empty and the plain text and the JSON silent about them; D30 defaults to on.
    @Test func withoutTheCountsTheKeysStayEmpty() throws {
        let report = DiagnosticsFixtures.representativeReport()
        #expect(report.settings.typoCorrection && report.settings.neverCorrectEntries == nil && report.counters == nil)
        let parsed = try #require(DiagnosticsRenderer.parseIssueBlock(DiagnosticsRenderer.issueBlock(report)))
        #expect(parsed["settings.typoCorrection"] == "true")
        #expect(parsed["settings.neverCorrectEntries"] == "")
        #expect(parsed["counters.corrections"] == "" && parsed["counters.correctionUndos"] == "")
        let labels = ReportLabels.labels(for: .english)
        let text = DiagnosticsRenderer.plainText(report, language: .english)
        #expect(!text.contains(labels.neverCorrectEntries) && !text.contains(labels.corrections))
        let json = String(decoding: try DiagnosticsRenderer.json(report), as: UTF8.self)
        #expect(!json.contains("neverCorrectEntries") && !json.contains("correctionUndos"))
    }

    /// PLT-R1202: the assembled settings section carries D30 and the list's size from the store, the effective D30
    /// (on by default) when the user never set it.
    @Test func theAssembledSettingsCarryD30AndTheCount() {
        let defaults = ReportSections.settings(SettingsState())
        #expect(defaults.typoCorrection && defaults.neverCorrectEntries == 0)
        var user = UserSettings()
        user.neverCorrect = ["androdi", "gramar"]
        #expect(ReportSections.settings(SettingsState(user: user)).neverCorrectEntries == 2)
    }
}

@Suite struct CorrectionCountersHookTests {
    /// ADR 0502, ADR 0323: the integration hooks' state carries the two counts next to the tap recoveries; a build
    /// before 1.1.0 sends neither, which a newer harness reads as nil.
    @Test func theHookStateCarriesTheCountsAndOlderStatesStillDecode() throws {
        let metrics = PlatformMetrics().snapshot()
        let state = AppStateSnapshot(
            processIdentifier: 1, hostState: .starting, firstKeyAfterSecureInputReleaseComposed: nil, tapRecoveries: 0,
            engineResetsAfterTapRecovery: 0, corrections: 3, correctionUndos: 1, metrics: metrics)
        #expect(state.corrections == 3 && state.correctionUndos == 1)
        let decoded = try JSONDecoder().decode(AppStateSnapshot.self, from: try JSONEncoder().encode(state))
        #expect(decoded == state)
        let older = AppStateSnapshot(processIdentifier: 1, state: .ready, metrics: metrics)
        #expect(older.corrections == nil && older.correctionUndos == nil)
        let text = String(decoding: try JSONEncoder().encode(older), as: UTF8.self)
        #expect(!text.contains("corrections"))
    }
}
